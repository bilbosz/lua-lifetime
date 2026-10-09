-- bench/run.lua: run the benchmarks. From the repository root:
--
--   lua5.1 bench/run.lua [--in-process] [--lifetime DIR] [FILE ...]
--   luajit bench/run.lua [--in-process] [--lifetime DIR] [FILE ...]
--
-- Runs every FILE (default: every bench/bench-*.lua, sorted) and what it
-- registered with bench.add. Standard output is one line per benchmark,
-- `name<TAB>ns/op<TAB>ratio` (bench/lib/bench.lua), in file order;
-- nothing else is written there. Errors go to standard error, and the
-- exit status is 1 when a file or a benchmark raised.
--
-- Each FILE runs in a process of its own (task 013): the interpreter
-- running this script, with the same interpreter options, runs
-- `bench/run.lua --in-process --lifetime DIR FILE`; the child inherits
-- the environment (BENCH_TIME) and standard error, and its standard
-- output is copied here line by line as it comes. A benchmark's number
-- then does not depend on which files ran before it: in one LuaJIT
-- process the trace cache and the heap left by the transpiler benchmarks
-- made `runtime/move` read 93 to 109 ns against 25 ns alone (task 002,
-- review round 1, F4). A child that exits with a status other than 0 is
-- reported here too, naming its file, and makes the exit status 1; the
-- other files still run.
--
-- `--in-process` loads every FILE into this one process and then runs
-- every benchmark, as bench/run.lua did before task 013; it is what a
-- child runs, and what the tests use when they need one process.
-- bench/README.md, "One process per benchmark file", says which numbers
-- to compare.
--
-- `--lifetime DIR` takes the modules `lifetime` and `lifetime.*` from
-- DIR/lifetime/ and nowhere else (default: the current directory). `make
-- bench BASE=<ref>` passes the base's checkout, build/base, so that the
-- branch's benchmark files and the branch's input files (read relative to
-- the current directory) run on the base's runtime and transpiler
-- (task 010, "compares the branch with `master` on the same machine").
-- The harness itself is always the branch's.
local lifetime_dir = "."
local in_process = false
local files = {}
local i = 1
while arg[i] do
    if arg[i] == "--lifetime" then
        lifetime_dir = assert(arg[i + 1], "--lifetime needs a directory")
        i = i + 2
    elseif arg[i] == "--in-process" then
        in_process = true
        i = i + 1
    else
        files[#files + 1] = arg[i]
        i = i + 1
    end
end

if #files == 0 then
    local p = io.popen("ls -1 bench/bench-*.lua 2>/dev/null")
    for path in p:lines() do
        files[#files + 1] = path
    end
    p:close()
    table.sort(files)
end

local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

-- One process per file.
local function run_each_in_own_process()
    -- The command line that started this script: arg[-n] .. arg[-1] are
    -- the interpreter and its options, arg[0] the script (Lua 5.1
    -- reference manual, 6, "Lua Stand-alone"; luajit fills arg the same
    -- way).
    local first = 0
    while arg[first - 1] ~= nil do
        first = first - 1
    end
    if first == 0 then
        io.stderr:write("bench: cannot tell which interpreter runs bench/run.lua (arg[-1] is nil); use --in-process\n")
        return 1
    end
    local command = {}
    for k = first, 0 do
        command[#command + 1] = shell_quote(arg[k])
    end
    command[#command + 1] = "--in-process --lifetime " .. shell_quote(lifetime_dir)
    local prefix = table.concat(command, " ") .. " "
    local status_file = os.tmpname()
    local failed = 0
    for _, path in ipairs(files) do
        -- The child's exit status goes to a file: io.popen's close says
        -- nothing about it under Lua 5.1, and the child's standard output
        -- stays benchmark lines only.
        os.remove(status_file)
        local p = assert(io.popen(prefix .. shell_quote(path) .. "; echo $? >" .. shell_quote(status_file), "r"))
        for line in p:lines() do
            io.stdout:write(line, "\n")
            io.stdout:flush()
        end
        p:close()
        local status = tonumber((read_file(status_file) or ""):match("%d+"))
        if status ~= 0 then
            failed = failed + 1
            io.stderr:write(string.format("bench: %s: its process exited with status %s\n", path, tostring(status)))
        end
    end
    os.remove(status_file)
    return failed
end

if not in_process then
    os.exit(run_each_in_own_process() == 0 and 0 or 1)
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

-- The module loader for `lifetime` and `lifetime.*`: DIR only. It raises
-- when the module is missing there rather than letting `require` fall
-- through to package.path, which would mix the branch's modules into a
-- base run.
local function lifetime_loader(name)
    if name ~= "lifetime" and name:sub(1, 9) ~= "lifetime." then
        return nil
    end
    local stem = lifetime_dir .. "/" .. name:gsub("%.", "/")
    for _, path in ipairs({stem .. ".lua", stem .. "/init.lua"}) do
        if file_exists(path) then
            return assert(loadfile(path))
        end
    end
    error(string.format("module '%s' not found under %s/", name, lifetime_dir), 0)
end
-- Second, after package.preload and before the package.path searcher.
table.insert(package.loaders, 2, lifetime_loader)

package.path = "./?.lua;./?/init.lua;" .. package.path
local bench = require("bench.lib.bench")

local failed = 0
for _, path in ipairs(files) do
    local ok, err = pcall(dofile, path)
    if not ok then
        failed = failed + 1
        io.stderr:write(string.format("bench: %s: %s\n", path, tostring(err)))
    end
end

failed = failed + bench.run()
os.exit(failed == 0 and 0 or 1)
