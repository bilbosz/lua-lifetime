-- tests/lib/test.lua: a minimal zero-dependency test framework, modelled
-- on Treflove's tests/lib/test.lua. Tests are grouped into suites; each
-- case runs in protected mode so one failure never stops the run.
--
--   local test = require("tests.lib.test")
--   test.suite("lexer")
--   test.case("numbers", function() test.assert_eq(1 + 1, 2) end)
--   ...
--   os.exit(test.report() == 0 and 0 or 1)

local test = {}

local suites = {}
local current_suite = nil

-- Start a new suite; later `test.case` calls are recorded under it.
function test.suite(name)
    current_suite = {name = name, passed = 0, failed = 0, failures = {}}
    table.insert(suites, current_suite)
end

-- Run one test case in protected mode.
function test.case(name, fn)
    local suite = assert(current_suite, "test.suite() must be called before test.case()")
    local ok, err = xpcall(fn, function(e)
        return tostring(e)
    end)
    if ok then
        suite.passed = suite.passed + 1
    else
        suite.failed = suite.failed + 1
        table.insert(suite.failures, {name = name, err = err})
    end
end

local function display(value)
    if type(value) == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
end

local function prefix(message)
    return message and (message .. ": ") or ""
end

function test.assert_eq(actual, expected, message)
    if actual ~= expected then
        error(string.format("%sexpected %s, got %s", prefix(message), display(expected), display(actual)), 2)
    end
end

function test.assert_true(value, message)
    if not value then
        error(string.format("%sexpected truthy value, got %s", prefix(message), display(value)), 2)
    end
end

function test.assert_false(value, message)
    if value then
        error(string.format("%sexpected falsy value, got %s", prefix(message), display(value)), 2)
    end
end

-- Assert that `fn` raises, and that the message contains `pattern` (a plain
-- substring) when one is given. Returns the message.
function test.assert_error(fn, pattern, message)
    local ok, err = pcall(fn)
    if ok then
        error(prefix(message) .. "expected an error, but none was raised", 2)
    end
    err = tostring(err)
    if pattern and not err:find(pattern, 1, true) then
        error(string.format("%sexpected an error containing %s, got %s", prefix(message), display(pattern), display(err)), 2)
    end
    return err
end

local function to_string(value, seen)
    if type(value) ~= "table" then
        return display(value)
    end
    seen = seen or {}
    if seen[value] then
        return "<cycle>"
    end
    seen[value] = true
    local keys = {}
    for k in pairs(value) do
        table.insert(keys, k)
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, k in ipairs(keys) do
        table.insert(parts, "[" .. display(k) .. "] = " .. to_string(value[k], seen))
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function deep_eq(a, b)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    for k, v in pairs(a) do
        if not deep_eq(v, b[k]) then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

-- Compare two values recursively: tables by structure, the rest by `==`.
-- The usual way to assert a destruction log: collect the destructor calls
-- in an array and compare it with the expected sequence as a whole.
function test.assert_deep_eq(actual, expected, message)
    if not deep_eq(actual, expected) then
        error(string.format("%sdeep equality failed:\n  actual:   %s\n  expected: %s", prefix(message), to_string(actual), to_string(expected)), 2)
    end
end

-- Print the results of every suite and return the number of failed cases.
function test.report()
    local total_passed, total_failed = 0, 0
    for _, suite in ipairs(suites) do
        total_passed = total_passed + suite.passed
        total_failed = total_failed + suite.failed
        local status = suite.failed == 0 and "PASS" or "FAIL"
        print(string.format("[%s] %-24s %3d passed, %d failed", status, suite.name, suite.passed, suite.failed))
        for _, failure in ipairs(suite.failures) do
            print(string.format("       * %s\n         %s", failure.name, failure.err))
        end
    end
    print(string.format("Total: %d passed, %d failed (%s)", total_passed, total_failed, _VERSION .. (jit and (" / " .. jit.version) or "")))
    return total_failed
end

return test
