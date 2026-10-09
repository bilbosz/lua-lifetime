-- tests/test-cli.lua: lifetime/cli.lua's `build` (tasks 001 and 006), the
-- pipeline of docs/04-transpiler.md, "Pipeline".
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

test.case("the extension builds to calls of the runtime, positions under the chunk name", function()
    -- Task 006 replaced task 005's placeholder, which wrote the extension
    -- back in its own spelling (docs/04-transpiler.md, "The generated
    -- chunk header", "What `@` expands to", "Blocks").
    test.assert_eq(cli.build("local x  =  {} @ lifetime.scope\nf !@ ( a,b )\n", "a.lt"), table.concat({
        "local lifetime = require(\"lifetime\"); local __lt_attach, __lt_hook, __lt_enter, __lt_exit = lifetime.attach, lifetime.hook, lifetime.enter, lifetime.exit;",
        " local __s1 = __lt_enter(\"a.lt:3\"); local x = __lt_attach({}, false, __s1)\n",
        "__lt_hook(f, nil, a, b)\n",
        "__lt_exit(__s1, \"a.lt:3\");"
    }))
end)

test.case("a goto into a block with a scope record returns nil and the message", function()
    -- docs/04-transpiler.md, "Blocks": "A `goto` into a block that needs a
    -- record is a compile error ("jumps into the scope of a lifetime")."
    local output, message = cli.build("goto inside\ndo\n    local r = {} @ lifetime.scope\n    ::inside::\nend\n", "a.lt")
    test.assert_eq(output, nil)
    test.assert_eq(message, "a.lt:1: <goto inside> jumps into the scope of a lifetime")
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
