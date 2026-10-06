-- tests/conformance.lua: the conformance runner (CLAUDE.md, rule 2;
-- examples/README.md is the contract).
--
-- For every examples/NAME.lt with an examples/NAME.lt.expected: transpile
-- it with lifetime.cli.build, write the output under build/examples/, and
-- run it under every interpreter found on PATH among `lua5.1` and
-- `luajit`, with the chunk name `examples/NAME.lt`. Standard output must
-- match the .expected file byte for byte; a final `!error: <prefix>` line
-- in the .expected file means the program must end with an uncaught error
-- whose message starts with the prefix. At least one interpreter must be
-- present, or the run fails loudly. Every example must pass.
--
-- Exposes `run(test)` for tests/run.lua, which records one test case per
-- example and interpreter, plus the collection checks.

local conformance = {}

local INTERPRETERS = {"lua5.1", "luajit"}
local EXAMPLES_DIR = "examples"
local BUILD_DIR = "build/examples"

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

-- Which of INTERPRETERS are on PATH, in that order.
function conformance.find_interpreters()
    local found = {}
    for _, name in ipairs(INTERPRETERS) do
        local r = run_shell("command -v " .. name)
        if r.status == 0 then
            table.insert(found, name)
        end
    end
    return found
end

-- Every NAME with a NAME.lt, and every NAME with a NAME.lt.expected; the
-- two sets must be equal (a missing partner is a collection error).
function conformance.discover(dir)
    local programs, expectations = {}, {}
    for _, name in ipairs(list_directory(dir)) do
        local stem = name:match("^(.+)%.lt$")
        if stem then
            programs[stem] = true
        end
        stem = name:match("^(.+)%.lt%.expected$")
        if stem then
            expectations[stem] = true
        end
    end
    local errors, names = {}, {}
    for stem in pairs(programs) do
        if not expectations[stem] then
            table.insert(errors, string.format("%s/%s.lt has no %s.lt.expected", dir, stem, stem))
        else
            table.insert(names, stem)
        end
    end
    for stem in pairs(expectations) do
        if not programs[stem] then
            table.insert(errors, string.format("%s/%s.lt.expected has no %s.lt", dir, stem, stem))
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

-- The driver that runs the generated file under the chunk name the
-- contract requires; a script rather than `-e`, since lua5.1 and luajit
-- set up `arg` differently for `-e` code.
local DRIVER = "tests/lib/driver.lua"

-- Run one example under one interpreter. Returns nil on success, or a
-- message describing the mismatch.
function conformance.check(name, interpreter)
    local source_path = EXAMPLES_DIR .. "/" .. name .. ".lt"
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
    os.execute("mkdir -p " .. shell_quote(BUILD_DIR))
    local output_path = BUILD_DIR .. "/" .. name .. ".lua"
    write_file(output_path, generated)
    local r = run_shell(string.format("%s %s %s %s", interpreter, shell_quote(DRIVER), shell_quote(output_path), shell_quote(source_path)))
    if r.stdout ~= expected_stdout then
        return string.format("stdout differs under %s\n--- expected ---\n%s--- actual ---\n%s--- stderr ---\n%s", interpreter, expected_stdout, r.stdout, r.stderr)
    end
    if expected_error then
        local message = r.stderr:match("^[^:\n]*: ([^\n]*)") or ""
        if r.status ~= 1 then
            return string.format("expected exit status 1 under %s, got %d; stderr:\n%s", interpreter, r.status, r.stderr)
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
    return interpreters
end

return conformance
