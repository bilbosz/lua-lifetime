-- tests/conformance.lua: the conformance runner (CLAUDE.md, rule 2;
-- examples/README.md is the contract).
--
-- For every examples/NAME.lt with an examples/NAME.lt.expected: transpile
-- it with lifetime.cli.build and write the output under build/examples/
-- (for inspection, and so that a build failure is reported as one), then
-- run it with `lifetime run examples/NAME.lt` (bin/lifetime, task 007)
-- under every interpreter found on PATH among `lua5.1` and `luajit`,
-- which gives it the chunk name `examples/NAME.lt`. Standard output must
-- match the .expected file byte for byte; a final `!error: <prefix>` line
-- in the .expected file means the program must end with an uncaught error
-- whose message starts with the prefix, reported by `lifetime run` as
-- `lifetime: <message>` with exit status 1. At least one interpreter must
-- be present, or the run fails loudly. Every example must pass.
--
-- The Teal examples (task 018; examples/README.md, "The Teal examples"):
-- every examples/teal/NAME.tlt with an examples/teal/NAME.tlt.expected is
-- built with the Teal front end (lifetime/teal.lua) to
-- build/examples/teal/NAME.tl and run with `lifetime run
-- examples/teal/NAME.tlt`, under the same contract, under every
-- interpreter on which `require("tl")` works; with the `tl` module on no
-- interpreter they are skipped with a note, since `tl` is the
-- teal-lifetime rock's dependency, not this repository's.
--
-- Exposes `run(test)` for tests/run.lua, which records one test case per
-- example and interpreter, plus the collection checks.

local conformance = {}

local INTERPRETERS = {"lua5.1", "luajit"}
local EXAMPLES_DIR = "examples"
local BUILD_DIR = "build/examples"
-- The two kinds of example: the source extension, the extension of the
-- transpiled file, the module the interpreter must have to run them.
local KINDS = {
    lua = {dir = EXAMPLES_DIR, build_dir = BUILD_DIR, source = ".lt", output = ".lua"},
    teal = {dir = EXAMPLES_DIR .. "/teal", build_dir = BUILD_DIR .. "/teal", source = ".tlt", output = ".tl", needs = "tl"}
}

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

local function write_file(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

local function run_shell(command)
    -- Portable across lua5.1 and luajit, whose os.execute return values
    -- differ: route stdout, stderr and the status through files.
    local out, err, status = os.tmpname(), os.tmpname(), os.tmpname()
    os.execute(string.format("sh -c %s >%s 2>%s; echo $? >%s", shell_quote(command), shell_quote(out), shell_quote(err), shell_quote(status)))
    local result = {stdout = read_file(out) or "", stderr = read_file(err) or "", status = tonumber((read_file(status) or ""):match("%d+")) or -1}
    os.remove(out)
    os.remove(err)
    os.remove(status)
    return result
end

local function list_directory(dir)
    local names = {}
    local p = io.popen("ls -1 " .. shell_quote(dir) .. " 2>/dev/null")
    for name in p:lines() do
        table.insert(names, name)
    end
    p:close()
    table.sort(names)
    return names
end

-- Which of INTERPRETERS are on PATH, in that order. With `module`, only
-- those on which `require(module)` succeeds.
function conformance.find_interpreters(module)
    local found = {}
    for _, name in ipairs(INTERPRETERS) do
        local r = run_shell("command -v " .. name)
        if r.status == 0 and module then
            r = run_shell(name .. " -e " .. shell_quote("require(" .. string.format("%q", module) .. ")"))
        end
        if r.status == 0 then
            table.insert(found, name)
        end
    end
    return found
end

-- Every NAME with a NAME<ext>, and every NAME with a NAME<ext>.expected
-- (`ext` is ".lt" unless given); the two sets must be equal (a missing
-- partner is a collection error).
function conformance.discover(dir, ext)
    ext = ext or ".lt"
    local programs, expectations = {}, {}
    local pattern = "^(.+)" .. ext:gsub("%.", "%%.") .. "$"
    local expected_pattern = "^(.+)" .. ext:gsub("%.", "%%.") .. "%.expected$"
    for _, name in ipairs(list_directory(dir)) do
        local stem = name:match(pattern)
        if stem then
            programs[stem] = true
        end
        stem = name:match(expected_pattern)
        if stem then
            expectations[stem] = true
        end
    end
    local errors, names = {}, {}
    for stem in pairs(programs) do
        if not expectations[stem] then
            table.insert(errors, string.format("%s/%s%s has no %s%s.expected", dir, stem, ext, stem, ext))
        else
            table.insert(names, stem)
        end
    end
    for stem in pairs(expectations) do
        if not programs[stem] then
            table.insert(errors, string.format("%s/%s%s.expected has no %s%s", dir, stem, ext, stem, ext))
        end
    end
    table.sort(names)
    table.sort(errors)
    return names, errors
end

-- Split an .expected file into the expected stdout and the expected error
-- prefix (nil when the program must finish without an uncaught error).
function conformance.parse_expected(data)
    local trimmed = data:match("^(.*)\n$") or data -- ignore one final newline
    local body, last = trimmed:match("^(.*\n)([^\n]*)$")
    if not body then
        body, last = "", trimmed
    end
    local prefix = last:match("^!error: (.*)$")
    if prefix then
        return body, prefix
    end
    return data, nil
end

-- The command that runs an example under the chunk name the contract
-- requires (examples/README.md): `<interpreter> bin/lifetime run
-- examples/NAME.lt`, from the repository root.
local COMMAND = "bin/lifetime"

-- The message of the uncaught-error report in `stderr`: the rest of its
-- first line that starts with `lifetime: ` (docs/04-transpiler.md, "The
-- command"). A destructor error routed to `lifetime_destroyerror` while the scopes
-- unwind is written before it, as `lifetime_destroyerror: ...`.
function conformance.reported_error(stderr)
    return ("\n" .. stderr):match("\nlifetime: ([^\n]*)")
end

-- Run one example under one interpreter: a Lua example (`kind` "lua",
-- the default) or a Teal one ("teal"). Returns nil on success, or a
-- message describing the mismatch.
function conformance.check(name, interpreter, kind)
    kind = KINDS[kind or "lua"]
    local source_path = kind.dir .. "/" .. name .. kind.source
    local source = read_file(source_path)
    if not source then
        return "cannot read " .. source_path
    end
    local expected_stdout, expected_error = conformance.parse_expected(read_file(source_path .. ".expected"))
    local cli = require("lifetime.cli")
    local generated, build_error = cli.build(source, source_path)
    if not generated then
        return "build failed: " .. tostring(build_error)
    end
    os.execute("mkdir -p " .. shell_quote(kind.build_dir))
    local output_path = kind.build_dir .. "/" .. name .. kind.output
    write_file(output_path, generated)
    local r = run_shell(string.format("%s %s run %s", interpreter, shell_quote(COMMAND), shell_quote(source_path)))
    if r.stdout ~= expected_stdout then
        return string.format("stdout differs under %s\n--- expected ---\n%s--- actual ---\n%s--- stderr ---\n%s", interpreter, expected_stdout, r.stdout, r.stderr)
    end
    if expected_error then
        local message = conformance.reported_error(r.stderr)
        if r.status ~= 1 then
            return string.format("expected exit status 1 under %s, got %d; stderr:\n%s", interpreter, r.status, r.stderr)
        end
        if not message then
            return string.format("expected an error reported as \"lifetime: <message>\" under %s; stderr:\n%s", interpreter, r.stderr)
        end
        if message:sub(1, #expected_error) ~= expected_error then
            return string.format("expected an error starting with %q under %s, got %q", expected_error, interpreter, message)
        end
    elseif r.status ~= 0 then
        return string.format("expected exit status 0 under %s, got %d; stderr:\n%s", interpreter, r.status, r.stderr)
    end
    return nil
end

-- Record the conformance cases into the given test module.
function conformance.run(test)
    test.suite("conformance")
    local interpreters = conformance.find_interpreters()
    test.case("at least one interpreter is on PATH", function()
        test.assert_true(#interpreters > 0, "none of " .. table.concat(INTERPRETERS, ", ") .. " found on PATH")
    end)
    local names, errors = conformance.discover(EXAMPLES_DIR)
    test.case("every example has its .expected and vice versa", function()
        test.assert_eq(table.concat(errors, "\n"), "")
    end)
    test.case("there is at least one example", function()
        test.assert_true(#names > 0)
    end)
    for _, name in ipairs(names) do
        for _, interpreter in ipairs(interpreters) do
            test.case(name .. " under " .. interpreter, function()
                local problem = conformance.check(name, interpreter)
                if problem then
                    error(problem, 0)
                end
            end)
        end
    end
    -- The Teal examples, on the interpreters that have the `tl` module.
    local teal = KINDS.teal
    local teal_interpreters = conformance.find_interpreters(teal.needs)
    local teal_names, teal_errors = conformance.discover(teal.dir, teal.source)
    test.case("every Teal example has its .expected and vice versa", function()
        test.assert_eq(table.concat(teal_errors, "\n"), "")
    end)
    test.case("there is at least one Teal example", function()
        test.assert_true(#teal_names > 0)
    end)
    if #teal_interpreters == 0 then
        print("note: the Teal examples are skipped: module tl is not installed under " .. table.concat(interpreters, " or "))
    end
    for _, name in ipairs(teal_names) do
        for _, interpreter in ipairs(teal_interpreters) do
            test.case("teal/" .. name .. " under " .. interpreter, function()
                local problem = conformance.check(name, interpreter, "teal")
                if problem then
                    error(problem, 0)
                end
            end)
        end
    end
    return interpreters, teal_interpreters
end

return conformance
