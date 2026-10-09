-- tests/test-cli.lua: lifetime/cli.lua's `build` (task 001), the pipeline
-- of docs/04-transpiler.md, "Pipeline".
local test = require("tests.lib.test")
local cli = require("lifetime.cli")

test.suite("cli.build")

test.case("a plain chunk builds to itself modulo whitespace", function()
    test.assert_eq(cli.build("local x  =  1\n\n-- c\nprint( x )\n", "a.lt"), "local x = 1\n\n\nprint(x)\n")
end)

test.case("a syntax error returns nil and the message", function()
    local output, message = cli.build("x @ ()", "a.lt")
    test.assert_eq(output, nil)
    test.assert_eq(message, "a.lt:1: empty anchor list near ')'")
    output, message = cli.build("\nlocal z = x @ y + 1", "examples/b.lt")
    test.assert_eq(output, nil)
    test.assert_eq(message, "examples/b.lt:2: unexpected symbol near '+'")
    output, message = cli.build("if a != b then end", "a.lt")
    test.assert_eq(output, nil)
    test.assert_eq(message, "a.lt:1: unexpected symbol near '!' (use '~=' for inequality)")
end)

test.case("until task 006, the extension builds to its own spelling", function()
    -- lifetime/emit.lua writes the nodes of task 005 back as written.
    test.assert_eq(cli.build("local x  =  {} @ lifetime.scope\nf !@ ( a,b )\n", "a.lt"), "local x = {} @ lifetime.scope\nf !@ (a, b)\n")
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
