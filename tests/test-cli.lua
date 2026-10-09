-- tests/test-cli.lua: lifetime/cli.lua's `build` (task 001), the pipeline
-- of docs/04-transpiler.md, "Pipeline".
local test = require("tests.lib.test")
local cli = require("lifetime.cli")

test.suite("cli.build")

test.case("a plain chunk builds to itself modulo whitespace", function()
    test.assert_eq(cli.build("local x  =  1\n\n-- c\nprint( x )\n", "a.lt"), "local x = 1\n\n\nprint(x)\n")
end)

test.case("a syntax error returns nil and the message", function()
    local output, message = cli.build("x @ y", "a.lt")
    test.assert_eq(output, nil)
    test.assert_eq(message, "a.lt:1: '=' expected near '@'")
    output, message = cli.build("\nlocal z = x @ y", "examples/b.lt")
    test.assert_eq(output, nil)
    test.assert_eq(message, "examples/b.lt:2: unexpected symbol near '@'")
end)

test.case("a malformed token returns nil and the message", function()
    local output, message = cli.build("x = 0x", "a.lt")
    test.assert_eq(output, nil)
    test.assert_eq(message, "a.lt:1: malformed number near '0x'")
end)

test.case("the output of examples/plain.lt runs under its chunk name", function()
    local f = assert(io.open("examples/plain.lt", "rb"))
    local source = f:read("*a")
    f:close()
    local output = assert(cli.build(source, "examples/plain.lt"))
    local chunk = assert(loadstring(output, "=examples/plain.lt"))
    test.assert_eq(type(chunk), "function")
end)
