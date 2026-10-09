-- bench/run.lua: run the benchmarks. From the repository root:
--
--   lua5.1 bench/run.lua [--lifetime DIR] [FILE ...]
--   luajit bench/run.lua [--lifetime DIR] [FILE ...]
--
-- Loads every FILE (default: every bench/bench-*.lua, sorted) and runs
-- what they registered with bench.add. Standard output is one line per
-- benchmark, `name<TAB>ns/op<TAB>ratio` (bench/lib/bench.lua); nothing
-- else is written there. Errors go to standard error, and the exit
-- status is 1 when a file or a benchmark raised.
--
-- `--lifetime DIR` takes the modules `lifetime` and `lifetime.*` from
-- DIR/lifetime/ and nowhere else (default: the current directory). `make
-- bench BASE=<ref>` passes the base's checkout, build/base, so that the
-- branch's benchmark files and the branch's input files (read relative to
-- the current directory) run on the base's runtime and transpiler
-- (task 010, "compares the branch with `master` on the same machine").
-- The harness itself is always the branch's.
local lifetime_dir = "."
local files = {}
local i = 1
while arg[i] do
    if arg[i] == "--lifetime" then
        lifetime_dir = assert(arg[i + 1], "--lifetime needs a directory")
        i = i + 2
    else
        files[#files + 1] = arg[i]
        i = i + 1
    end
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

if #files == 0 then
    local p = io.popen("ls -1 bench/bench-*.lua 2>/dev/null")
    for path in p:lines() do
        files[#files + 1] = path
    end
    p:close()
    table.sort(files)
end

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
