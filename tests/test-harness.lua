-- tests/test-harness.lua: the harness and the conformance runner's pure
-- parts, so that the unit suite is not empty at the bootstrap and the
-- .expected contract (examples/README.md) is pinned.
local test = require("tests.lib.test")
local conformance = require("tests.conformance")

test.suite("harness")

test.case("assert_deep_eq compares structure", function()
    test.assert_deep_eq({"a", "b", x = {1}}, {"a", "b", x = {1}})
    test.assert_error(function()
        test.assert_deep_eq({"a", "b"}, {"b", "a"})
    end, "deep equality failed")
end)

test.case("assert_error checks the message", function()
    test.assert_error(function()
        error("boom")
    end, "boom")
    test.assert_error(function()
        test.assert_error(function() end)
    end, "expected an error")
end)

test.suite("conformance contract")

test.case("plain output", function()
    local out, err = conformance.parse_expected("a\nb\n")
    test.assert_eq(out, "a\nb\n")
    test.assert_eq(err, nil)
end)

test.case("error line at the end", function()
    local out, err = conformance.parse_expected("a\n!error: examples/x.lt:3: boom\n")
    test.assert_eq(out, "a\n")
    test.assert_eq(err, "examples/x.lt:3: boom")
end)

test.case("error line without a trailing newline", function()
    local out, err = conformance.parse_expected("a\n!error: boom")
    test.assert_eq(out, "a\n")
    test.assert_eq(err, "boom")
end)

test.case("error line alone", function()
    local out, err = conformance.parse_expected("!error: boom\n")
    test.assert_eq(out, "")
    test.assert_eq(err, "boom")
end)

test.case("the reported error is the first line that starts with lifetime: (task 007)", function()
    test.assert_eq(conformance.reported_error("lifetime: examples/x.lt:3: boom\nstack traceback:\n\t[C]: in function 'error'\n"), "examples/x.lt:3: boom")
    -- A destructor error routed to destroyerror while the scopes unwind
    -- is written first.
    test.assert_eq(conformance.reported_error("destroyerror: examples/x.lt:5: late\nstack traceback:\n\t...\nlifetime: examples/x.lt:3: boom\n"), "examples/x.lt:3: boom")
    test.assert_eq(conformance.reported_error("lua5.1: examples/x.lt:3: boom\n"), nil)
    test.assert_eq(conformance.reported_error(""), nil)
end)

test.case("discover pairs programs with expectations", function()
    local names, errors = conformance.discover("examples")
    test.assert_true(#names >= 1)
    test.assert_eq(#errors, 0)
end)
