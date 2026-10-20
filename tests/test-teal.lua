-- tests/test-teal.lua: the Teal front end (task 018), lifetime/teal.lua
-- with the dialect hooks of lifetime/lexer.lua, lifetime/parser.lua,
-- lifetime/emit.lua and lifetime/cli.lua: docs/01-overview.md, "Rocks";
-- docs/05-decisions.md, "`!@` survives Teal's macro operator";
-- docs/04-transpiler.md, "The Teal front end".
local test = require("tests.lib.test")
local lexer = require("lifetime.lexer")
local parser = require("lifetime.parser")
local emit = require("lifetime.emit")
local cli = require("lifetime.cli")
local teal = require("lifetime.teal")
local chunks = require("tests.lib.chunks")

local dialect = teal.dialect

local function tokenize(source)
    return lexer.tokenize(source, "t", true, "teal")
end

local function parse(source, chunkname)
    chunkname = chunkname or "t.tlt"
    return parser.parse(lexer.tokenize(source, chunkname, true, "teal"), chunkname, dialect)
end

-- Teal in, Teal out.
local function round_trip(source, chunkname)
    return emit.emit(parse(source, chunkname), chunkname or "t.tlt", dialect)
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

-- The tokens of a source, as `type:value` strings, without <eof>.
local function token_list(source)
    local out = {}
    for _, t in ipairs(tokenize(source)) do
        if t.type ~= "eof" then
            out[#out + 1] = t.type .. ":" .. tostring(t.value)
        end
    end
    return out
end

-- The tags of a chunk's statements.
local function tags(chunk)
    local out = {}
    for i = 1, #chunk do
        out[i] = chunk[i].tag
    end
    return out
end

-- Is the `tl` module loadable in this interpreter?
local HAS_TL = pcall(require, "tl")

-- Every form Teal adds to Lua 5.1 (tl's docs/grammar.md), one statement
-- per line, with no extension syntax: it must come back as it went in.
local TEAL_FORMS = table.concat({
    "local x: number = 1", -- 1  typed local
    "local a <const>, b <close>: string, {string: number} = 's', {}", -- 2  attributes, a type list
    "local function f<T, U is Named>(a: T, b?: U, ...: string): T, U", -- 3  type arguments, optional, typed vararg, returns
    "    return a, b", -- 4
    "end", -- 5
    "local g = function(cb: function(string): boolean, n: integer): (boolean, integer) return cb('x'), n end", -- 6  function types, parenthesised returns
    "global counter: integer = 0", -- 7  global declaration
    "global function h(v: number | string): string return tostring(v) end", -- 8  global function with a union
    "local record R", -- 9  record
    "    name: string", -- 10
    "    tags: {string}", -- 11
    "    map: {string: {number, boolean}}", -- 12 map and tuple types
    "    metamethod __call: function(self: R, n: integer): R", -- 13
    "    ['quoted key']: boolean", -- 14
    "    type Alias = {R}", -- 15
    "    record Inner", -- 16
    "        v: integer", -- 17
    "    end", -- 18
    "    enum Mode", -- 19
    "        'a' 'b'", -- 20
    "    end", -- 21
    "end", -- 22
    "local interface Named", -- 23
    "    name: string", -- 24
    "end", -- 25
    "local record Box<T> is Named, {T}", -- 26 generic record with an interface list and an array part
    "    where self.kind == 'box'", -- 27 where clause (an expression)
    "    kind: string", -- 28
    "    userdata", -- 29
    "    first: function(self: Box<T>): T = macroexp(self: Box<T>): T return self[1] end", -- 30 macroexp field
    "end", -- 31
    "local enum Color 'red' 'green' end", -- 32 enum
    "local type Pair = {number, number}", -- 33 type alias
    "local type Mod = require('mod').Sub", -- 34 require type
    "local macroexp twice(n: number): number return n * 2 end", -- 35 macroexp
    "global type Shape = record x: number end", -- 36 global type with a record
    "global type Opaque", -- 37 a global type without a definition
    "local y = x as integer // 2 + (1 as number) ^ -2 as number", -- 38 as, //
    "local z = (x is number) and 3 & 1 | 2 ~ 4 << 1 >> 1 or ~x", -- 39 is, bitwise operators
    "local w, v = f(1, 2) as (integer, string)", -- 40 tuple cast
    "local t = {name: string = 'n', [1] = 2, 3}", -- 41 typed table field
    "local nested, deep: Box<Box<integer>>, {string: Map<string, {Box<Box<Named>>}>} = nil, nil", -- 42 nested generics, `>>` closing two lists
    "for k, val in pairs(t as {string: any}) do print(k, val) end", -- 43
    "print(m!(1, 2), m!'s', m!{1})", -- 44 Teal's macro call
    "m!(x)", -- 45 a macro call as a statement
    "return x", -- 46
    ""
}, "\n")

test.suite("teal lexer")

test.case("Teal's operators are tokens with the dialect and two symbols without it", function()
    test.assert_deep_eq(token_list("a // b << c >> d & e | f ~ g ~= h ? i"), {"name:a", "symbol://", "name:b", "symbol:<<", "name:c", "symbol:>>", "name:d", "symbol:&", "name:e", "symbol:|", "name:f", "symbol:~", "name:g", "symbol:~=", "name:h", "symbol:?", "name:i"})
    local plain = {}
    for _, t in ipairs(lexer.tokenize("a // b << c >> d", "t", true)) do
        if t.type ~= "eof" then
            plain[#plain + 1] = t.value
        end
    end
    test.assert_deep_eq(plain, {"a", "/", "/", "b", "<", "<", "c", ">", ">", "d"})
end)

test.case("`!@` is one token before Teal's `!`; `!=` is still reported", function()
    -- docs/05-decisions.md, "`!@` survives Teal's macro operator": "`!`
    -- immediately followed by `@` is `!@`; any other `!` is Teal's."
    test.assert_deep_eq(token_list("f !@ a"), {"name:f", "symbol:!@", "name:a"})
    test.assert_deep_eq(token_list("m!(a) !@ s"), {"name:m", "symbol:!", "symbol:(", "name:a", "symbol:)", "symbol:!@", "name:s"})
    test.assert_deep_eq(token_list("m!@ s"), {"name:m", "symbol:!@", "name:s"})
    test.assert_deep_eq(token_list("m ! @ s"), {"name:m", "symbol:!", "symbol:@", "name:s"})
    local tokens = tokenize("a != b")
    test.assert_eq(tokens[#tokens].type, "error")
    test.assert_eq(tokens[#tokens].value, "t:1: unexpected symbol near '!' (use '~=' for inequality)")
end)

test.suite("teal parser")

test.case("every Teal form parses, statement by statement", function()
    local chunk = parse(TEAL_FORMS)
    test.assert_deep_eq(tags(chunk), {
        "Local", "Local", "LocalFunction", "Local", "Global", "GlobalFunction", "Teal", "Teal", "Teal", "Teal", "Teal", "Teal", "Teal", "Teal", "Teal", "Local", "Local", "Local", "Local", "Local",
        "GenericFor", "CallStat", "CallStat", "Return"
    })
    -- The typed pieces hang on the nodes the Lua grammar has.
    local x = chunk[1]
    test.assert_eq(x.types.tag, "Raw")
    test.assert_eq(x.types[1].text, ":")
    test.assert_eq(x.types[2].text, "number")
    local ab = chunk[2]
    test.assert_eq(ab.names[1].attrib[2].text, "const")
    test.assert_eq(ab.names[2].attrib[2].text, "close")
    local f = chunk[3].func
    test.assert_eq(f.typeargs[1].text, "<")
    test.assert_eq(f.params[2].opt, 3)
    test.assert_eq(f.params[2].type[2].text, "U")
    test.assert_eq(f.vararg_type[2].text, "string")
    test.assert_eq(f.rets[1].text, ":")
    test.assert_eq(f.rets.n, 4)
    -- `as` binds above everything, `is` at the comparisons' level.
    local y = chunk[16].exprs[1]
    test.assert_eq(y.tag, "BinOp")
    test.assert_eq(y.op, "+")
    test.assert_eq(y.left.tag, "BinOp")
    test.assert_eq(y.left.op, "//")
    test.assert_eq(y.left.left.tag, "As")
    test.assert_eq(y.right.tag, "BinOp")
    test.assert_eq(y.right.op, "^")
    -- `-2 as number` is `-(2 as number)`: `as` binds above the unary
    -- operators (tl.tl, `precedences`).
    test.assert_eq(y.right.right.tag, "UnOp")
    test.assert_eq(y.right.right.operand.tag, "As")
    local z = chunk[17].exprs[1]
    test.assert_eq(z.tag, "BinOp")
    test.assert_eq(z.op, "or")
    test.assert_eq(z.left.op, "and")
    test.assert_eq(z.left.left.expr.tag, "Is")
    test.assert_eq(z.right.tag, "UnOp")
    test.assert_eq(z.right.op, "~")
    local wv = chunk[18].exprs[1]
    test.assert_eq(wv.tag, "As")
    test.assert_eq(wv.arity, 2)
    test.assert_eq(chunk[19].exprs[1].fields[1].type[2].text, "string")
    -- `>>` closes two lists: the inner takes one `>`, the outer the other.
    local nested = chunk[20].types
    local text = {}
    for i = 1, nested.n do
        text[i] = nested[i].text
    end
    test.assert_eq(table.concat(text, " "), ": Box < Box < integer > > , { string : Map < string , { Box < Box < Named > > } > }")
    local m = chunk[22].call.args[1]
    test.assert_eq(m.tag, "Macro")
    test.assert_eq(m.func.name, "m")
    test.assert_eq(#m.args, 2)
    test.assert_true(chunk[22].call.args[2].sugar)
    test.assert_eq(chunk[23].call.tag, "Macro")
    -- The where clause and the macroexp bodies are expressions inside the
    -- kept tokens.
    local box = chunk[9].raw
    local nodes = 0
    for i = 1, box.n do
        if box[i].tag then
            nodes = nodes + 1
        end
    end
    test.assert_eq(nodes, 2)
end)

test.case("Teal's `!` is a macro call, `!@` a hook", function()
    -- Test case 6: `m!(a) !@ s` is a macro call hooked to the scope,
    -- `m!@ s` is `m` hooked to `s`.
    local chunk = parse("local h = f !@ a\nlocal k = m!(a) !@ lifetime.scope\nm!@ s\nm!(1) !@ s @ t\n")
    test.assert_eq(chunk[1].exprs[1].tag, "Hook")
    test.assert_eq(chunk[1].exprs[1].expr.name, "f")
    local k = chunk[2].exprs[1]
    test.assert_eq(k.tag, "Hook")
    test.assert_eq(k.expr.tag, "Macro")
    test.assert_eq(k.anchors[1].tag, "ScopeAnchor")
    test.assert_eq(chunk[3].tag, "HookStat")
    test.assert_eq(chunk[3].expr.expr.name, "m")
    test.assert_eq(chunk[4].tag, "AnchorStat")
    test.assert_eq(chunk[4].expr.expr.tag, "Hook")
    test.assert_eq(chunk[4].expr.expr.expr.tag, "Macro")
end)

test.case("Teal's contextual words are ordinary names where Teal reads them so", function()
    -- tl.tl, parse_local and parse_global: `local type = 1` declares a
    -- local named `type`; `global` followed by anything but a Name or
    -- `function` is a name.
    local chunk = parse("local type, record, enum = 1, 2, 3\nglobal = type + record\nglobal.x = enum\nlocal is, as = 1, 2\nprint(is, as, global)\n")
    test.assert_deep_eq(tags(chunk), {"Local", "Set", "Set", "Local", "CallStat"})
    test.assert_eq(chunk[1].names[1].name, "type")
    test.assert_eq(chunk[2].targets[1].name, "global")
end)

test.case("syntax errors of the Teal grammar take Lua's shape", function()
    local function fails(source, message)
        local ok, err = pcall(parse, source, "a.tlt")
        test.assert_false(ok, source)
        test.assert_eq(err, message, source)
    end
    fails("local x: = 1", "a.tlt:1: expected a type near '='")
    fails("local record R\n    name: string\n", "a.tlt:3: 'end' expected (to close 'record' at line 1) near '<eof>'")
    fails("local enum E 1 end", "a.tlt:1: expected a string literal near '1'")
    fails("local t: {string", "a.tlt:1: '}' expected near '<eof>'")
    fails("local x = y as", "a.tlt:1: expected a type near '<eof>'")
    fails("local function f<>() end", "a.tlt:1: '<name>' expected near '>'")
    -- Lua's errors are unchanged by the dialect.
    fails("x @ ()", "a.tlt:1: empty anchor list near ')'")
    fails("local x = 0x", "a.tlt:1: malformed number near '0x'")
end)

test.case("the Lua chunks parse to the same AST with and without the dialect", function()
    -- CLAUDE.md, rule 5: the dialect adds nothing to Lua. The test chunks
    -- of the Lua grammar and of the extension are the same trees.
    for _, source in ipairs({chunks.EVERY_FORM, chunks.EXTENDED}) do
        local plain = parser.parse(lexer.tokenize(source, "t", true), "t")
        local with = parser.parse(lexer.tokenize(source, "t", true, "teal"), "t", dialect)
        test.assert_deep_eq(with, plain)
    end
end)

test.suite("teal emit")

test.case("parse -> emit -> parse gives an equal AST, lines included", function()
    local ast = parse(TEAL_FORMS)
    local again = parse(emit.emit(ast, "t.tlt", dialect))
    test.assert_deep_eq(again, ast)
end)

test.case("a Teal chunk with no extension syntax comes back token for token, line for line", function()
    -- docs/04-transpiler.md, "Pipeline": a chunk with no extension syntax
    -- is its input modulo whitespace and comments.
    local sources = {TEAL_FORMS, read_file("examples/teal/plain.tlt"), read_file("lifetime/init.d.tl")}
    for i, source in ipairs(sources) do
        local output = round_trip(source)
        local before, after = tokenize(source), tokenize(output)
        test.assert_eq(#after, #before, i .. ": number of tokens")
        for k = 1, #before do
            test.assert_deep_eq(after[k], before[k], i .. ": token " .. k)
        end
    end
end)

test.case("a chunk in the emitter's own layout comes out byte for byte", function()
    local source = table.concat({
        "local record Res",
        "    name: string",
        "    items: {string: {integer}}",
        "    metamethod __call: function(self: Res, n?: integer): Res",
        "    end",
        "local function greet<T>(name: T, ...: string): string, integer",
        "    local n <const>: integer = select(\"#\", ...)",
        "    return tostring(name) as string, n",
        "end",
        "print(greet(\"x\") as (string, integer))",
        ""
    }, "\n")
    test.assert_eq(round_trip(source), source)
end)

test.case("the extension builds to the typed shape of docs/04", function()
    -- The header, `__lt_attach` keeping the operand, the scope record,
    -- the hook with the binding's name, the packed return with its cast.
    local source = table.concat({
        "local function serve(sock: Socket): string, integer",
        "    local conn: Conn = Conn.open(sock) @ lifetime.scope",
        "    local h = function(reason: lifetime.Reason) print(reason) end !@ conn",
        "    local buf = Buffer.new(1) @ (conn, h)",
        "    return pair(buf)",
        "end",
        ""
    }, "\n")
    test.assert_eq(round_trip(source, "a.tlt"), table.concat({
        "local lifetime = require(\"lifetime\"); local __lt_attach, __lt_named_hook, __lt_enter, __lt_exit = lifetime.attach, lifetime.named_hook, lifetime.enter, lifetime.exit; " .. dialect.pack_header .. " local function serve(sock: Socket): string, integer local __s1 = __lt_enter(\"a.tlt:6\");",
        "    local conn: Conn = __lt_attach(Conn.open(sock), __s1)",
        "    local h = __lt_named_hook(\"h\", function(reason: lifetime.Reason) print(reason) end, conn)",
        "    local buf = __lt_attach(Buffer.new(1), conn, h)",
        "    local __r, __n = __lt_pack(pair(buf)); __lt_exit(__s1, \"a.tlt:5\"); return __lt_unpack(__r, 1, __n) as (string, integer)",
        "end",
        ""
    }, "\n"))
end)

test.case("the cast of a packed return follows the declared returns", function()
    local function returns(rets)
        local source = "local function f()" .. rets .. "\n    local x = {} @ lifetime.scope\n    return g()\nend\n"
        local output = round_trip(source)
        return output:match("return __lt_unpack%(__r, 1, __n%)([^\n]*)")
    end
    test.assert_eq(returns(": string"), " as (string)")
    test.assert_eq(returns(": string, {integer}"), " as (string, {integer})")
    test.assert_eq(returns(": (string, Map<string, number>)"), " as (string, Map<string, number>)")
    -- No declared returns, or a vararg tail, which no cast can spell: tl
    -- reports the `any...` as it would for any such return.
    test.assert_eq(returns(""), "")
    test.assert_eq(returns(": string, number..."), "")
    -- A tuple cast as the last value is as many values as it names, with
    -- no packing.
    local output = round_trip("local function f(): string, integer\n    local x = {} @ lifetime.scope\n    return g() as (string, integer)\nend\n")
    test.assert_true(output:find("local __r1, __r2 = g() as (string, integer); __lt_exit(__s1, \"t.tlt:3\"); return __r1, __r2", 1, true) ~= nil, output)
    test.assert_false(output:find("__lt_pack", 1, true))
end)

test.case("the `lifetime.scope` inside a where clause or a cast counts for its block", function()
    -- docs/04-transpiler.md, "Blocks": a block needs a record when it
    -- contains `lifetime.scope` as an anchor directly; a dialect's
    -- expressions are walked like any other.
    local output = round_trip("local record R\n    where (self.x @ lifetime.scope) ~= nil\n    x: integer\nend\n")
    test.assert_true(output:find("__lt_enter", 1, true) ~= nil, output)
    output = round_trip("local y = ({} @ lifetime.scope) as R\n")
    test.assert_true(output:find("(__lt_attach({}, __s1)) as R", 1, true) ~= nil, output)
end)

test.suite("teal cli")

test.case("cli.build picks the Teal dialect from the extension or the argument", function()
    local source = "local x: integer = 1 @ lifetime.scope\n"
    local expected = "local lifetime = require(\"lifetime\"); local __lt_attach, __lt_enter, __lt_exit = lifetime.attach, lifetime.enter, lifetime.exit; local __s1 = __lt_enter(\"a.tlt:2\"); local x: integer = __lt_attach(1, __s1)\n__lt_exit(__s1, \"a.tlt:2\");"
    test.assert_eq(cli.build(source, "a.tlt"), expected)
    test.assert_eq(cli.build(source, "a.tlt", "teal"), expected)
    test.assert_eq(cli.lang_of("a.tlt"), "teal")
    test.assert_eq(cli.lang_of("a.lt"), "lua")
    test.assert_eq(cli.lang_of("a.tl"), "lua")
    -- As Lua, the type annotation is a syntax error.
    test.assert_deep_eq({cli.build(source, "a.tlt", "lua")}, {nil, "a.tlt:1: unexpected symbol near ':'"})
    test.assert_deep_eq({cli.build(source, "a.lt")}, {nil, "a.lt:1: unexpected symbol near ':'"})
end)

test.case("every .lt example builds the same with the dialect argument absent and \"lua\"", function()
    local p = assert(io.popen("ls -1 examples/*.lt"))
    local n = 0
    for path in p:lines() do
        local source = read_file(path)
        test.assert_eq(cli.build(source, path, "lua"), cli.build(source, path), path)
        n = n + 1
    end
    p:close()
    test.assert_true(n > 10)
end)

test.case("a missing front end is reported, not raised", function()
    local saved = package.loaded["lifetime.teal"]
    package.loaded["lifetime.teal"] = nil
    local saved_path = package.path
    package.path = "/nonexistent/?.lua"
    local ok, err = pcall(function()
        test.assert_deep_eq({cli.build("local x = 1", "a.tlt")}, {nil, "cannot build a.tlt: the Teal front end is not installed (module lifetime.teal, the teal-lifetime rock)"})
        test.assert_eq(cli.build("local x = 1", "a.lt"), "local x = 1")
    end)
    package.path = saved_path
    package.loaded["lifetime.teal"] = saved
    assert(ok, err)
end)

if HAS_TL then
    test.case("tl reports no error on the generated Teal and on lifetime/init.d.tl", function()
        local tl = require("tl")
        local function check(source, name)
            local env = assert(tl.new_env({defaults = {gen_target = "5.1"}}))
            local result = tl.check_string(source, env, name, "tl")
            local messages = {}
            for _, list in ipairs({result.syntax_errors, result.type_errors}) do
                for _, e in ipairs(list or {}) do
                    messages[#messages + 1] = string.format("%s:%d:%d: %s", e.filename, e.y, e.x, e.msg)
                end
            end
            test.assert_eq(table.concat(messages, "\n"), "", name)
        end
        check(read_file("lifetime/init.d.tl"), "lifetime/init.d.tl")
        for _, name in ipairs({"plain", "connection", "scope_exit", "exit_paths", "uncaught_error", "generics"}) do
            local path = "examples/teal/" .. name .. ".tlt"
            check(assert(cli.build(read_file(path), path)), path)
        end
    end)

    test.case("teal.compile gives Lua that keeps its lines, or tl's errors", function()
        -- The error on line 6 is reported at line 6: tl keeps the lines.
        local lua = assert(teal.compile("local x: integer = 1\n\nlocal function f(): string\n    return tostring(x)\nend\nerror(f())\n", "a.tlt"))
        local chunk = assert(loadstring(lua, "=a.tlt"))
        local ok, err = pcall(chunk)
        test.assert_false(ok)
        test.assert_eq(err, "a.tlt:6: 1")
        local none, message = teal.compile("local x: integer = 'a'\nlocal y: string = 1\n", "a.tlt")
        test.assert_eq(none, nil)
        test.assert_eq(message, "a.tlt:1:20: in local declaration: x: got string \"a\", expected integer\na.tlt:2:19: in local declaration: y: got integer, expected string")
        none, message = teal.compile("local x = = 1\n", "a.tlt")
        test.assert_eq(none, nil)
        test.assert_true(message:find("^a%.tlt:1:11: ") ~= nil, message)
    end)
end

------------------------------------------------------------------------
-- The command on .tlt files: bin/lifetime under every interpreter that
-- has the tl module (docs/04-transpiler.md, "The Teal front end").
------------------------------------------------------------------------

test.suite("teal command")

local conformance = require("tests.conformance")
local INTERPRETERS = conformance.find_interpreters()
local TL_INTERPRETERS = conformance.find_interpreters("tl")
local SCRATCH = "build/test-teal"

local function quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

os.execute("mkdir -p " .. quote(SCRATCH))

local function shell(command)
    local err_path = os.tmpname()
    local p = assert(io.popen("{ " .. command .. "; } 2>" .. quote(err_path) .. "; echo \"<status $?>\""))
    local out = p:read("*a")
    p:close()
    local stderr = read_file(err_path) or ""
    os.remove(err_path)
    local status = tonumber(out:match("<status (%d+)>\n$"))
    return (out:gsub("<status %d+>\n$", "")), stderr, status
end

local function lifetime(interpreter, args)
    return shell(interpreter .. " bin/lifetime " .. args)
end

if #TL_INTERPRETERS == 0 then
    print("note: the Teal command tests are skipped: module tl is not installed under " .. table.concat(INTERPRETERS, " or "))
end

for _, interpreter in ipairs(INTERPRETERS) do
    test.case("build FILE.tlt -o - writes Teal (" .. interpreter .. ")", function()
        local path = "examples/teal/connection.tlt"
        local out, err, status = lifetime(interpreter, "build " .. path .. " -o -")
        test.assert_eq(err, "")
        test.assert_eq(status, 0)
        test.assert_eq(out, assert(cli.build(read_file(path), path)))
        test.assert_true(out:find("local record Connection", 1, true) ~= nil)
    end)

    test.case("a syntax error in a .tlt prints FILE:LINE: <message> (" .. interpreter .. ")", function()
        local path = SCRATCH .. "/syntax-error.tlt"
        write_file(path, "local x: integer = 1\nx @ ()\n")
        test.assert_deep_eq({lifetime(interpreter, "build " .. path .. " -o -")}, {"", path .. ":2: empty anchor list near ')'\n", 1})
        test.assert_deep_eq({lifetime(interpreter, "run " .. path)}, {"", "lifetime: " .. path .. ":2: empty anchor list near ')'\n", 1})
    end)
end

for _, interpreter in ipairs(TL_INTERPRETERS) do
    local function case(name, fn)
        test.case(name .. " (" .. interpreter .. ")", fn)
    end

    case("run FILE.tlt compiles with tl and runs with arg and the exit flag", function()
        local path = SCRATCH .. "/args.tlt"
        write_file(path, table.concat({
            "local record R",
            "    name: string",
            "end",
            "local R_mt = {__lifetime_destroy = function(self: R, reason: lifetime.Reason) print(\"destroy \" .. self.name .. \" (\" .. reason .. \")\") end} as metatable<R>",
            "global kept: R = setmetatable({name = \"global\"} as R, R_mt) @ lifetime.reachable",
            "local main = setmetatable({name = \"main\"} as R, R_mt) @ lifetime.scope",
            "print(arg[0], arg[1], arg[2], select(\"#\", ...), main.name)",
            ""
        }, "\n"))
        local out, err, status = lifetime(interpreter, "run " .. path .. " a b")
        test.assert_eq(err, "")
        test.assert_eq(status, 0)
        test.assert_eq(out, path .. "\ta\tb\t2\tmain\ndestroy main (anchor)\ndestroy global (exit)\n")
    end)

    case("build FILE.tlt -o OUT.lua compiles the Teal with tl", function()
        local target = SCRATCH .. "/out-" .. interpreter .. ".lua"
        os.remove(target)
        test.assert_deep_eq({lifetime(interpreter, "build examples/teal/connection.tlt -o " .. target)}, {"", "", 0})
        local lua = read_file(target)
        test.assert_true(lua:find("local Connection = {}", 1, true) ~= nil, lua)
        test.assert_false(lua:find("record", 1, true))
        -- The Lua runs under the interpreter, with the runtime on the path.
        local out, err, status = shell(interpreter .. " -e " .. quote("package.path='./?.lua;./?/init.lua;'..package.path; require('lifetime')") .. " " .. quote(target))
        test.assert_eq(err, "")
        test.assert_eq(status, 0)
        test.assert_eq(out, read_file("examples/teal/connection.tlt.expected"))
    end)

    case("a type error is reported as FILE:LINE:COL: <message> with exit status 1", function()
        local path = SCRATCH .. "/type-error.tlt"
        write_file(path, "local x: integer = 1 @ lifetime.scope\nlocal y: string = x\n")
        local out, err, status = lifetime(interpreter, "run " .. path)
        test.assert_eq(out, "")
        test.assert_eq(err, "lifetime: " .. path .. ":2:19: in local declaration: y: got integer, expected string\n")
        test.assert_eq(status, 1)
        -- Several errors: one `lifetime: ` per line.
        write_file(path, "local x: integer = \"a\" @ lifetime.scope\nlocal y: string = 1\n")
        out, err, status = lifetime(interpreter, "run " .. path)
        test.assert_eq(out, "")
        test.assert_eq(status, 1)
        test.assert_eq(select(2, err:gsub("\nlifetime: ", "")), 1, err)
        test.assert_true(err:find("^lifetime: " .. path:gsub("%p", "%%%0") .. ":1:%d+: ") ~= nil, err)
        test.assert_true(err:find("\nlifetime: " .. path:gsub("%p", "%%%0") .. ":2:19: in local declaration: y: got integer, expected string\n$") ~= nil, err)
        write_file(path, "local x: integer = 1 @ lifetime.scope\nlocal y: string = x\n")
        -- `build -o OUT.lua` reports the same, bare.
        out, err, status = lifetime(interpreter, "build " .. path .. " -o " .. SCRATCH .. "/type-error.lua")
        test.assert_eq(out, "")
        test.assert_eq(err, path .. ":2:19: in local declaration: y: got integer, expected string\n")
        test.assert_eq(status, 1)
        -- `build -o -` writes the Teal without checking it.
        out, err, status = lifetime(interpreter, "build " .. path .. " -o -")
        test.assert_eq(err, "")
        test.assert_eq(status, 0)
        test.assert_true(out:find("local y: string = x", 1, true) ~= nil)
    end)

    case("an uncaught error unwinds the scopes and is reported from the .tlt line", function()
        local path = SCRATCH .. "/raise.tlt"
        write_file(path, "local h = function(reason: lifetime.Reason) print(\"hook \" .. reason) end !@ lifetime.scope\n\nerror(\"boom\")\n")
        local out, err, status = lifetime(interpreter, "run " .. path)
        test.assert_eq(out, "hook anchor\n")
        test.assert_eq(status, 1)
        test.assert_true(err:find("^lifetime: " .. path:gsub("%p", "%%%0") .. ":3: boom\n") ~= nil, err)
    end)

    case("a missing tl is reported when run needs it", function()
        local path = SCRATCH .. "/no-tl.tlt"
        write_file(path, "local x: integer = 1\nprint(x)\n")
        -- The front end is on the path, tl is not: `-e` hides it.
        local out, err, status = shell(interpreter .. " -e " .. quote("package.preload['tl'] = function() error('no tl here') end") .. " bin/lifetime run " .. path)
        test.assert_eq(out, "")
        test.assert_eq(err, "lifetime: cannot compile " .. path .. ": the Teal compiler is not installed (module tl, the tl rock)\n")
        test.assert_eq(status, 1)
        -- `build -o OUT.tl` needs no tl.
        out, err, status = shell(interpreter .. " -e " .. quote("package.preload['tl'] = function() error('no tl here') end") .. " bin/lifetime build " .. path .. " -o -")
        test.assert_eq(err, "")
        test.assert_eq(status, 0)
        test.assert_eq(out, "local x: integer = 1\nprint(x)\n")
    end)

    case("the front end runs from an installed layout, outside the checkout", function()
        -- The layout `luarocks make` gives the two rocks (task 007's test
        -- for the first): lua-lifetime's modules under the tree's
        -- share/lua/5.1, teal-lifetime's lifetime/teal.lua and
        -- lifetime/init.d.tl next to them, the script in lua-lifetime's
        -- bin/. tl finds the declaration file through `?/init.lua`.
        local root = assert(os.getenv("PWD"), "PWD is not set")
        local tree = os.tmpname()
        os.remove(tree)
        local share = tree .. "/share/lua/5.1"
        local rock_bin = tree .. "/lib/luarocks/rocks-5.1/lua-lifetime/dev-1/bin"
        local elsewhere = tree .. "/elsewhere"
        os.execute("mkdir -p " .. quote(share .. "/lifetime") .. " " .. quote(rock_bin) .. " " .. quote(elsewhere))
        for _, spec_path in ipairs({"lua-lifetime-dev-1.rockspec", "teal-lifetime-dev-1.rockspec"}) do
            local chunk = assert(loadfile(spec_path))
            local env = {}
            setfenv(chunk, env)
            chunk()
            for name, file in pairs(env.build.modules) do
                local target = share .. "/" .. name:gsub("%.", "/") .. (file:match("init%.lua$") and "/init.lua" or ".lua")
                write_file(target, read_file(file))
            end
            for name, file in pairs(env.build.install and env.build.install.lua or {}) do
                -- luarocks (build.lua, install_to; path.module_to_path): a
                -- string key is a module name, the file goes into that
                -- module's directory (the key without its last component,
                -- dots to slashes), and a file that is not .lua keeps its
                -- name.
                local directory = name:match("^(.*)%.[^.]*$") or ""
                write_file(share .. "/" .. directory:gsub("%.", "/") .. "/" .. file:match("[^/]+$"), read_file(file))
            end
        end
        write_file(rock_bin .. "/lifetime", read_file("bin/lifetime"))
        local path = share .. "/?.lua;" .. share .. "/?/init.lua;"
        local out, err, status = shell("cd " .. quote(elsewhere) .. " && " .. interpreter .. " -e " .. quote("package.path=" .. string.format("%q", path) .. "..package.path") .. " " .. quote(rock_bin .. "/lifetime") .. " run " .. quote(root .. "/examples/teal/connection.tlt"))
        os.execute("rm -rf " .. quote(tree))
        test.assert_eq(err, "")
        test.assert_eq(status, 0)
        test.assert_eq(out, read_file("examples/teal/connection.tlt.expected"))
    end)
end

-- `luarocks make` of the second rockspec, where luarocks is installed:
-- the layout it gives (task 018's acceptance criterion, as task 007's
-- test could not check with no luarocks on its machine). Only the
-- dependencies need the network; `--deps-mode=none` skips them.
local HAS_LUAROCKS = select(3, shell("command -v luarocks")) == 0

if HAS_LUAROCKS then
    test.case("luarocks make teal-lifetime-dev-1.rockspec installs the front end next to the runtime", function()
        local tree = os.tmpname()
        os.remove(tree)
        local out, err, status = shell("luarocks --lua-version 5.1 make --deps-mode=none --tree " .. quote(tree) .. " teal-lifetime-dev-1.rockspec")
        local share = tree .. "/share/lua/5.1"
        local teal_module, declaration = read_file(share .. "/lifetime/teal.lua"), read_file(share .. "/lifetime/init.d.tl")
        os.execute("rm -rf " .. quote(tree))
        test.assert_eq(status, 0, out .. err)
        test.assert_eq(teal_module, read_file("lifetime/teal.lua"))
        test.assert_eq(declaration, read_file("lifetime/init.d.tl"))
    end)
else
    print("note: the luarocks make test is skipped: luarocks is not on PATH")
end
