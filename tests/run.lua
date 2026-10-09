-- tests/run.lua: the test suite entry point. Run from the repository root:
--
--   lua5.1 tests/run.lua [unit|conformance|all]     (default: all)
--   luajit tests/run.lua [unit|conformance|all]
--
-- `make test` runs the unit suite under every interpreter found and the
-- conformance suite once, which itself runs every example under every
-- interpreter found (tests/conformance.lua).
package.path = "./?.lua;./?/init.lua;" .. package.path

local test = require("tests.lib.test")

-- Unit test modules, one per module under test (tests/test-<module>.lua).
-- Add new files here.
local TEST_MODULES = {
    "tests.test-harness",
    "tests.test-lexer",
    "tests.test-parser",
    "tests.test-emit",
    "tests.test-cli"
}

local what = arg and arg[1] or "all"
if what ~= "unit" and what ~= "conformance" and what ~= "all" then
    io.stderr:write("usage: tests/run.lua [unit|conformance|all]\n")
    os.exit(2)
end

if what == "unit" or what == "all" then
    for _, module_name in ipairs(TEST_MODULES) do
        require(module_name)
    end
end

if what == "conformance" or what == "all" then
    local interpreters = require("tests.conformance").run(test)
    print("conformance interpreters: " .. (#interpreters > 0 and table.concat(interpreters, ", ") or "none"))
end

local failed = test.report()
io.stdout:flush()
os.exit(failed == 0 and 0 or 1)
