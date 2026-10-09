-- tests/test-emit.lua: lifetime/emit.lua (task 001). A plain Lua chunk
-- transpiles to itself modulo whitespace, with every statement (indeed
-- every token) on its source line, so that error positions survive the
-- round trip (docs/04-transpiler.md, "Pipeline").
local test = require("tests.lib.test")
local lexer = require("lifetime.lexer")
local parser = require("lifetime.parser")
local emit = require("lifetime.emit")
local chunks = require("tests.lib.chunks")

local function parse(source, chunkname)
    chunkname = chunkname or "t"
    return parser.parse(lexer.tokenize(source, chunkname), chunkname)
end

local function round_trip(source, chunkname)
    return emit.emit(parse(source, chunkname))
end

-- The message of the error that running `source` raises, loaded under
-- `chunkname`.
local function run_error(source, chunkname)
    local chunk = assert(loadstring(source, "=" .. chunkname))
    local ok, err = pcall(chunk)
    assert(not ok, "the chunk ran without an error")
    return err
end

local function read_file(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return data
end

-- Every plain Lua source of this repository: the transpiler, the runtime,
-- the tests, the command and the example that uses no extension syntax.
-- The other examples are the extension's (see "every example builds to a
-- chunk that loads, with its lines" below).
local function corpus()
    local paths = {}
    local p = io.popen("ls lifetime/*.lua tests/*.lua tests/lib/*.lua examples/plain.lt bin/lifetime 2>/dev/null")
    for path in p:lines() do
        paths[#paths + 1] = path
    end
    p:close()
    return paths
end

-- A source as luaL_loadfile reads it: a first line starting with `#` is
-- skipped, its line break kept.
local function without_shebang(source)
    return (source:gsub("^#[^\n]*", ""))
end

test.suite("emit")

test.case("parse -> emit -> parse gives an equal AST, lines included", function()
    local ast = parse(chunks.EVERY_FORM)
    local again = parse(emit.emit(ast))
    test.assert_deep_eq(again, ast)
end)

test.case("error() on line 7 is reported at line 7 after the round trip", function()
    local source = table.concat({
        "-- examples/x.lt", -- 1
        "local s = [[", -- 2
        "a long string]]", -- 3
        "--[==[ a long", -- 4
        "comment ]==] local t = {", -- 5
        "}", -- 6
        "error(\"boom\")", -- 7
        "print(s, t)" -- 8
    }, "\n")
    local output = round_trip(source, "examples/x.lt")
    test.assert_eq(run_error(output, "examples/x.lt"), "examples/x.lt:7: boom")
    test.assert_eq(run_error(source, "examples/x.lt"), "examples/x.lt:7: boom")
end)

test.case("runtime errors inside multi-line expressions keep Lua's position", function()
    local sources = {
        "local t = nil\nlocal x = math.max(\n    1,\n    t.x\n)",
        "local t = {}\nlocal x = t.a\n    .b\n    .c",
        "local x = 1 +\n    {}",
        "local x = {} <\n\n    {}",
        "local f = function(a)\n    return a.b\nend\nf(nil)",
        "for i = nil,\n    2\ndo\nend",
        "local t = {}\nt\n[\nnil\n] = 1",
        "local s = [[\n\n]] .. {}",
        "local function f()\n    error('deep', 2)\nend\nlocal function g()\n    f()\nend\ng()"
    }
    for _, source in ipairs(sources) do
        local output = round_trip(source, "m.lt")
        test.assert_eq(run_error(output, "m.lt"), run_error(source, "m.lt"), string.format("%q", source))
    end
end)

test.case("every repository source: the same tokens on the same lines, the same bytecode", function()
    local paths = corpus()
    test.assert_true(#paths >= 10, "corpus of " .. #paths .. " files")
    for _, path in ipairs(paths) do
        local source = without_shebang(read_file(path))
        local output = round_trip(source, path)
        -- Modulo whitespace and comments, the output is its input.
        local before, after = lexer.tokenize(source, path), lexer.tokenize(output, path)
        test.assert_eq(#after, #before, path .. ": number of tokens")
        for i = 1, #before do
            test.assert_deep_eq(after[i], before[i], path .. ": token " .. i)
        end
        -- Lua compiles both to the same function, line information
        -- included, under this interpreter.
        local f_source = assert(loadstring(source, "=" .. path))
        local f_output = assert(loadstring(output, "=" .. path))
        test.assert_true(string.dump(f_output) == string.dump(f_source), path .. ": bytecode differs")
    end
end)

test.case("a chunk in the emitter's own layout comes out byte for byte", function()
    local source = table.concat({
        "local items = {\"gamma\", 'alpha', [[beta]]}",
        "local function greet(name, ...)",
        "    if not name then",
        "        return nil",
        "    elseif #name > 0 then",
        "        return \"hello, \" .. name, -1, ...",
        "    end",
        "    for i = 1, #items do",
        "        items[i] = items[i]:upper()",
        "    end",
        "",
        "    local t = {x = 1, [2] = 3; 4}",
        "    t.x, t[2] = f {t}, g \"s\"",
        "end",
        "print(greet(\"x\"))",
        ""
    }, "\n")
    test.assert_eq(round_trip(source), source)
end)

test.case("comments go, their lines stay", function()
    test.assert_eq(round_trip("-- one\nlocal x = 1 -- two\n--[[ three\nfour ]] print(x)\n"), "\nlocal x = 1\n\nprint(x)\n")
    test.assert_eq(round_trip("-- only a comment\n"), "\n")
    test.assert_eq(round_trip(""), "")
    test.assert_eq(round_trip("x = 1"), "x = 1")
end)

test.case("tokens that would lex differently when adjacent are kept apart", function()
    local source = "x = a - -b - - -1 .. 2 .. t[ [[s]] ] .. t[ [=[s]=] ] .. 1 .. .5 == - - #- -c"
    local output = round_trip(source)
    test.assert_deep_eq(lexer.tokenize(output, "t"), lexer.tokenize(source, "t"))
end)

test.case("a call after a Name on a new line inside a table constructor round-trips", function()
    -- Review round 1, F1: Lua accepts `{ f\n(x) }` as a call.
    local source = "local function f(v) return v end\nlocal x = { f\n(1) }\nlocal t = { f\n\n(2) }\nreturn x[1] + t[1]"
    local ast = parse(source)
    local output = emit.emit(ast)
    test.assert_deep_eq(parse(output), ast)
    test.assert_deep_eq(lexer.tokenize(output, "t"), lexer.tokenize(source, "t"))
    local f_source, f_output = assert(loadstring(source, "=t")), assert(loadstring(output, "=t"))
    test.assert_true(string.dump(f_output) == string.dump(f_source), "bytecode differs")
    test.assert_eq(f_output(), 3)
end)

test.case("several statements on one line stay on it", function()
    test.assert_eq(round_trip("local a = 1 local b = 2; a = b\nprint(a)"), "local a = 1 local b = 2; a = b\nprint(a)")
    test.assert_eq(round_trip("x = 1 (f)()"), "x = 1 (f)()")
end)

-- The number of lines of a text.
local function count_lines(text)
    local _, n = text:gsub("\n", "")
    return n + 1
end

-- The lines on which the statements of a chunk's main block start.
local function statement_lines(source)
    local lines = {}
    for _, s in ipairs(parse(source)) do
        lines[s.line] = true
    end
    return lines
end

test.case("the extension's statements stay on their source lines", function()
    -- Replaces task 005's placeholder ("the extension's nodes come back in
    -- their spelling, every token on its line"): with task 006 the
    -- extension becomes calls, written on the lines of the tokens they
    -- replace (docs/04-transpiler.md, "Pipeline": "where generated code
    -- needs extra lines it is written on the same line, separated by
    -- `;`").
    local output = emit.emit(parse(chunks.EXTENDED), "t")
    test.assert_eq(count_lines(output), count_lines(chunks.EXTENDED))
    local starts = statement_lines(output)
    for _, line in ipairs(chunks.EXTENDED_STATEMENT_LINES) do
        test.assert_true(starts[line], "no statement starts on line " .. line .. " of\n" .. output)
    end
    -- Chained statements (docs/04-transpiler.md, "Grammar"), over lines.
    local chained = "f !@ a @ b\nfunction() end !@ a\n  @ (b,\n  lifetime.scope) !@ c\nx\n@\nlifetime\n.\nscope\n@\nd\n"
    output = emit.emit(parse(chained), "t")
    test.assert_eq(count_lines(output), count_lines(chained))
    starts = statement_lines(output)
    test.assert_true(starts[1] and starts[2] and starts[5], output)
    local compact = output:gsub("%s", "")
    test.assert_true(compact:find("__lt_hook(__lt_attach(__lt_hook(function()end,nil,a),false,b,__s1),nil,c)", 1, true), output)
    test.assert_true(compact:find("__lt_attach(__lt_attach(x,false,__s1),false,d)", 1, true), output)
end)

test.case("LuaJIT's syntax round-trips; under LuaJIT, to the same bytecode", function()
    -- docs/05-decisions.md, "The lexer accepts LuaJIT's lexical
    -- extensions": a byte order mark, a `#` first line, bytes >= 128 in
    -- names, `\z` before a line break, the FFI suffixes; and `goto`.
    local source = table.concat({
        "\239\187\191#!/usr/bin/env luajit", -- 1
        "local caf\195\169 = 0x10ULL + 2LL", -- 2
        "local s = \"a\\z", -- 3
        "    b\" .. 'c\\z d'", -- 4
        "for i = 1, 3 do", -- 5
        "    if i == 2 then goto skip end", -- 6
        "    s = s .. i", -- 7
        "    ::skip::", -- 8
        "end", -- 9
        "return s, 1i, 0b101, caf\195\169" -- 10
    }, "\n")
    local output = round_trip(source, "j.lt")
    test.assert_eq(output:sub(1, 1), "\n")
    test.assert_deep_eq(lexer.tokenize(output, "j.lt"), lexer.tokenize(source, "j.lt"))
    if jit then
        local f_source = assert(loadstring(source, "=j.lt"))
        local f_output = assert(loadstring(output, "=j.lt"))
        test.assert_true(string.dump(f_output) == string.dump(f_source), "bytecode differs")
        -- LuaJIT reads `\z` its own way wherever it stands.
        test.assert_eq(select(1, f_output()), "abcd13")
    end
end)

test.case("a node without token lines is written at its statement's line", function()
    -- Later stages build nodes that carry `line` but no `lines`, and values
    -- without a source spelling.
    local ast = {
        tag = "Block",
        {
            tag = "CallStat",
            line = 3,
            call = {tag = "Call", line = 3, func = {tag = "Id", name = "print"}, args = {{tag = "String", value = "a\nb"}, {tag = "Number", value = 1.5}}}
        }
    }
    test.assert_eq(emit.emit(ast), "\n\nprint(\"a\\nb\", 1.5)\n")
end)

------------------------------------------------------------------------
-- Task 006: the extension (docs/04-transpiler.md, "The generated chunk
-- header", "What `@` expands to", "Blocks: prologue and epilogue on every
-- exit path", "Functions").
------------------------------------------------------------------------

test.suite("emit: the extension")

local function build(source, chunkname)
    chunkname = chunkname or "c.lt"
    return emit.emit(parse(source, chunkname), chunkname)
end

-- The header a chunk gets for the runtime functions it calls.
local LT = "local lifetime = require(\"lifetime\");"
local ATTACH = LT .. " local __lt_attach = lifetime.attach;"
local HOOK = LT .. " local __lt_hook = lifetime.hook;"
local SCOPE = LT .. " local __lt_attach, __lt_enter, __lt_exit = lifetime.attach, lifetime.enter, lifetime.exit;"
local SCOPE_HOOK = LT .. " local __lt_hook, __lt_enter, __lt_exit = lifetime.hook, lifetime.enter, lifetime.exit;"
local PACK = " local __lt_unpack, __lt_select = unpack, select; local function __lt_pack(...) return {n = __lt_select(\"#\", ...), ...} end;"

-- Load generated code under `chunkname` and call it with the arguments;
-- the runtime is the one tests/run.lua's package.path finds.
local function run(output, chunkname, ...)
    local chunk = assert(loadstring(output, "=" .. (chunkname or "c.lt")))
    return chunk(...)
end

-- A constructor of objects whose destructor appends to `log`.
local function logger(log)
    local mt = {
        __destroy = function(self, reason)
            log[#log + 1] = self.name .. " " .. reason
        end
    }
    return function(name)
        return setmetatable({name = name}, mt)
    end
end

test.case("a chunk that names no builtin as a global is emitted unchanged", function()
    -- "a chunk that uses no extension syntax and names no lifetime builtin
    -- gets no header and is its input unchanged": a local named like a
    -- builtin is the program's own.
    local sources = {
        "local lifetime = require(\"lifetime\")\nlocal destroy = lifetime.destroy\ndestroy(x)\n",
        "local function f(discard) return discard end",
        "local function destroy() end\ndestroy()",
        "for destroy, discard in pairs(t) do print(destroy, discard) end",
        "for lifetime = 1, 2 do print(lifetime) end",
        "repeat local lifetime = f() until lifetime.done",
        "local t = {destroy = 1, lifetime = 2}\nprint(t.destroy, t.lifetime, t:discard())"
    }
    for _, source in ipairs(sources) do
        test.assert_eq(build(source), round_trip(source), source)
        test.assert_false(build(source):find("__lt_", 1, true), source)
    end
end)

test.case("a builtin named as a global is bound by the header, and only it", function()
    test.assert_eq(build("destroy(x)"), LT .. " local destroy = lifetime.destroy; destroy(x)")
    test.assert_eq(build("discard(x) destroy(y)"), LT .. " local destroy, discard = lifetime.destroy, lifetime.discard; discard(x) destroy(y)")
    test.assert_eq(build("print(lifetime.alive(x))"), LT .. " print(lifetime.alive(x))")
    -- The value of `local destroy = destroy` is the global; a local's scope
    -- ends with its block.
    test.assert_eq(build("local destroy = destroy"), LT .. " local destroy = lifetime.destroy; local destroy = destroy")
    test.assert_eq(build("do local discard end\ndiscard(x)"), LT .. " local discard = lifetime.discard; do local discard end\ndiscard(x)")
    test.assert_eq(build("local function f(destroy) end\ndestroy(x)"), LT .. " local destroy = lifetime.destroy; local function f(destroy) end\ndestroy(x)")
    -- An empty first line stays empty but for the header (a `#` line the
    -- lexer skipped).
    test.assert_eq(build("\ndestroy(x)"), LT .. " local destroy = lifetime.destroy;\ndestroy(x)")
    -- The header binds the runtime that `require` finds.
    local lifetime = require("lifetime")
    local destroyed = run(build("local t = setmetatable({}, {__destroy = function() end})\ndestroy(t)\nreturn t"))
    test.assert_eq(getmetatable(destroyed), "dead")
    test.assert_true(run(build("return lifetime")) == lifetime)
end)

test.case("each row of the expansion table", function()
    -- docs/04-transpiler.md, "What `@` expands to".
    test.assert_eq(build("local x = e @ a"), ATTACH .. " local x = __lt_attach(e, false, a)")
    test.assert_eq(build("x = e @ (a, b)"), ATTACH .. " x = __lt_attach(e, false, a, b)")
    test.assert_eq(build("x = e @ lifetime.pin(a, b)"), ATTACH .. " x = __lt_attach(e, false, (lifetime.pin(a, b)))")
    test.assert_eq(build("x @ a"), ATTACH .. " __lt_attach(x, false, a)")
    test.assert_eq(build("t.x @ (a, b)"), ATTACH .. " __lt_attach(t.x, false, a, b)")
    test.assert_eq(build("f !@ a"), HOOK .. " __lt_hook(f, nil, a)")
    test.assert_eq(build("f !@ (a, b)"), HOOK .. " __lt_hook(f, nil, a, b)")
    test.assert_eq(build("local p = lifetime.token(\"p\") @ self"), ATTACH .. " local p = __lt_attach(lifetime.token(\"p\"), false, self)")
    test.assert_eq(build("do local x = e @ lifetime.scope end"), SCOPE .. " do local __s1 = __lt_enter(\"c.lt:1\"); local x = __lt_attach(e, false, __s1) __lt_exit(__s1, \"c.lt:1\"); end")
    test.assert_eq(build("do f !@ lifetime.scope end"), SCOPE_HOOK .. " do local __s1 = __lt_enter(\"c.lt:1\"); __lt_hook(f, nil, __s1) __lt_exit(__s1, \"c.lt:1\"); end")
    test.assert_eq(build("do x = e @ (a, lifetime.scope) end"), SCOPE .. " do local __s1 = __lt_enter(\"c.lt:1\"); x = __lt_attach(e, false, a, __s1) __lt_exit(__s1, \"c.lt:1\"); end")
end)

test.case("a hook bound to a name is created with the name", function()
    -- docs/02-semantics.md, "Named hooks": `local NAME =`, `NAME =` and
    -- `t.NAME =` name the hook, each target its own; `t[k] =`, an
    -- argument or a statement on its own leave it anonymous.
    test.assert_eq(build("local h = f !@ a"), HOOK .. " local h = __lt_hook(f, \"h\", a)")
    test.assert_eq(build("h = f !@ a"), HOOK .. " h = __lt_hook(f, \"h\", a)")
    test.assert_eq(build("self.on_close = f !@ a"), HOOK .. " self.on_close = __lt_hook(f, \"on_close\", a)")
    test.assert_eq(build("t[k] = f !@ a"), HOOK .. " t[k] = __lt_hook(f, nil, a)")
    test.assert_eq(build("g(f !@ a)"), HOOK .. " g(__lt_hook(f, nil, a))")
    test.assert_eq(build("local h1, h2 = f !@ a, g !@ (a, b)"), HOOK .. " local h1, h2 = __lt_hook(f, \"h1\", a), __lt_hook(g, \"h2\", a, b)")
    test.assert_eq(build("local m = f !@ a @ b"), LT .. " local __lt_attach, __lt_hook = lifetime.attach, lifetime.hook; local m = __lt_attach(__lt_hook(f, \"m\", a), false, b)")
    test.assert_eq(build("local m = (f !@ a)"), HOOK .. " local m = (__lt_hook(f, \"m\", a))")
end)

test.case("a list of one is the plain form; an anchor item is one value", function()
    -- Task 005's notes for task 006: `x @ (a)` and `x @ a` emit alike, and
    -- `(lifetime.scope)` as the bare spelling; a call or `...` as the last
    -- item is truncated to one value (docs/02-semantics.md, "Acquiring a
    -- lifetime": "Evaluate each element").
    test.assert_eq(build("x @ (a)"), build("x @ a"))
    test.assert_eq(build("do x @ (lifetime.scope) end"), build("do x @ lifetime.scope end"))
    test.assert_eq(build("x @ (a, f())"), ATTACH .. " __lt_attach(x, false, a, (f()))")
    test.assert_eq(build("x @ g()"), ATTACH .. " __lt_attach(x, false, (g()))")
    test.assert_eq(build("x @ t:owner()"), ATTACH .. " __lt_attach(x, false, (t:owner()))")
    test.assert_eq(build("local function f(...) x @ (a, ...) end"), ATTACH .. " local function f(...) __lt_attach(x, false, a, (...)) end")
    test.assert_eq(build("f() !@ g()"), HOOK .. " __lt_hook(f(), nil, (g()))")
    -- The parenthesised prefixexp `(lifetime.scope).f` is the marker's
    -- field, not the scope anchor: no record.
    test.assert_eq(build("x @ (lifetime.scope).f"), ATTACH .. " __lt_attach(x, false, (lifetime.scope).f)")
    -- At run time each item is one value: a call returning two anchors
    -- anchors to the first only.
    local lifetime = require("lifetime")
    local a, b = {}, {}
    local x = run(build("local a, b = ...\nlocal function two() return a, b end\nreturn {} @ two()"), "c.lt", a, b)
    local deps_a, deps_b = lifetime.dependents(a), lifetime.dependents(b)
    test.assert_eq(#deps_a, 1)
    test.assert_true(deps_a[1] == x)
    test.assert_eq(#deps_b, 0)
end)

test.case("a statement chain is nested calls whatever its first operator", function()
    -- Task 005's note for task 006: a HookStat may wrap a chain whose first
    -- operator is `@` (docs/05-decisions.md, "A statement chains `@` and
    -- `!@` like an expression").
    local both = LT .. " local __lt_attach, __lt_hook = lifetime.attach, lifetime.hook;"
    test.assert_eq(build("f @ a !@ b"), both .. " __lt_hook(__lt_attach(f, false, a), nil, b)")
    test.assert_eq(build("f !@ a @ b"), both .. " __lt_attach(__lt_hook(f, nil, a), false, b)")
    test.assert_eq(build("function() end !@ a"), HOOK .. " __lt_hook(function() end, nil, a)")
    test.assert_eq(build("(x) @ a"), ATTACH .. " __lt_attach((x), false, a)")
end)

test.case("a block that does not anchor to lifetime.scope is emitted verbatim", function()
    -- docs/04-transpiler.md, "Blocks": "Only such blocks get code; every
    -- other block is emitted verbatim." "Directly": an anchor in a nested
    -- block or a nested function belongs to that block.
    test.assert_eq(build("do local x = {} @ a end"), ATTACH .. " do local x = __lt_attach({}, false, a) end")
    test.assert_eq(build("do\n    do\n        x @ lifetime.scope\n    end\nend"),
        SCOPE .. " do\n    do local __s1 = __lt_enter(\"c.lt:4\");\n        __lt_attach(x, false, __s1)\n    __lt_exit(__s1, \"c.lt:4\"); end\nend")
    test.assert_eq(build("do\n    local f = function()\n        g !@ lifetime.scope\n    end\nend"),
        SCOPE_HOOK .. " do\n    local f = function() local __s1 = __lt_enter(\"c.lt:4\");\n        __lt_hook(g, nil, __s1)\n    __lt_exit(__s1, \"c.lt:4\"); end\nend")
end)

test.case("a function that does not anchor to lifetime.scope is emitted verbatim", function()
    -- docs/04-transpiler.md, "Functions": "A function that does not is
    -- emitted verbatim, and a call costs what it costs in Lua." Nothing
    -- per function, even in a chunk whose other blocks have records.
    local plain = "local function f(a, ...)\n    if a then\n        return f(nil, ...)\n    end\n    return ...\nend\n"
    local output = build(plain .. "do\n    x @ lifetime.scope\nend\n")
    local head = SCOPE .. " "
    test.assert_eq(output:sub(1, #head), head)
    test.assert_eq(output:sub(#head + 1, #head + #plain), plain)
    local f_plain = assert(loadstring(plain, "=c.lt"))
    local f_output = assert(loadstring(output:sub(#head + 1, #head + #plain), "=c.lt"))
    test.assert_true(string.dump(f_output) == string.dump(f_plain), "bytecode differs")
end)

test.case("the main chunk is a block: its record ends at <eof>", function()
    test.assert_eq(build("local x = {} @ lifetime.scope\nprint(x)\n"),
        SCOPE .. " local __s1 = __lt_enter(\"c.lt:3\"); local x = __lt_attach({}, false, __s1)\nprint(x)\n__lt_exit(__s1, \"c.lt:3\");")
    -- A first statement that starts with `(` stays a statement.
    test.assert_eq(build("(f)()\nx @ lifetime.scope"), SCOPE .. " local __s1 = __lt_enter(\"c.lt:2\"); (f)()\n__lt_attach(x, false, __s1) __lt_exit(__s1, \"c.lt:2\");")
    local log = {}
    run(build("local res = ...\n(function() end)()\nlocal a = res(\"a\") @ lifetime.scope\n"), "c.lt", logger(log))
    test.assert_deep_eq(log, {"a anchor"})
end)

test.case("enter and exit take constant positions: the block's end, the exit's line", function()
    -- docs/04-transpiler.md, "Blocks": "The position passed to `enter` is
    -- that of the block's `end` ... the position passed to `exit` is that
    -- of the exit that runs it. Both are constant `"chunk:line"` strings".
    local source = table.concat({
        "local res = ...", -- 1
        "local kept = {}", -- 2
        "for i = 1, 2 do", -- 3
        "    local t = res(\"t\" .. i) @ lifetime.scope", -- 4
        "    kept[i] = t", -- 5
        "    if i == 2 then", -- 6
        "        break", -- 7
        "    end", -- 8
        "end", -- 9
        "return kept" -- 10
    }, "\n")
    local output = build(source, "examples/p.lt")
    test.assert_true(output:find("__lt_enter(\"examples/p.lt:9\")", 1, true), output)
    test.assert_true(output:find("__lt_exit(__s1, \"examples/p.lt:7\"); break", 1, true), output)
    test.assert_true(output:find("__lt_exit(__s1, \"examples/p.lt:9\"); end", 1, true), output)
    local log = {}
    local kept = run(output, "examples/p.lt", logger(log))
    test.assert_deep_eq(log, {"t1 anchor", "t2 anchor"})
    local _, message = pcall(function()
        return kept[1].name
    end)
    test.assert_true(message:find("died at examples/p.lt:9, anchor", 1, true), message)
    _, message = pcall(function()
        return kept[2].name
    end)
    test.assert_true(message:find("died at examples/p.lt:7, anchor", 1, true), message)
end)

test.case("return: values first, then every epilogue innermost first, trailing nils kept", function()
    -- docs/04-transpiler.md, "Blocks", **`return explist`**.
    test.assert_eq(build("local function f()\n    local a = {} @ lifetime.scope\n    return\nend"),
        SCOPE .. " local function f() local __s1 = __lt_enter(\"c.lt:4\");\n    local a = __lt_attach({}, false, __s1)\n    __lt_exit(__s1, \"c.lt:3\"); return\nend")
    test.assert_eq(build("local function f()\n    local a = {} @ lifetime.scope\n    return a.x, nil\nend"),
        SCOPE .. " local function f() local __s1 = __lt_enter(\"c.lt:4\");\n    local a = __lt_attach({}, false, __s1)\n    local __r1, __r2 = a.x, nil; __lt_exit(__s1, \"c.lt:3\"); return __r1, __r2\nend")
    test.assert_eq(build("local function f(...)\n    local a = {} @ lifetime.scope\n    return a, g(...)\nend"),
        SCOPE .. PACK .. " local function f(...) local __s1 = __lt_enter(\"c.lt:4\");\n    local a = __lt_attach({}, false, __s1)\n    local __r = __lt_pack(a, g(...)); __lt_exit(__s1, \"c.lt:3\"); return __lt_unpack(__r, 1, __r.n)\nend")
    -- Two blocks deep: the inner epilogue, then the function body's. A
    -- block without a record between them runs nothing.
    local source = table.concat({
        "local res = ...", -- 1
        "local function f(how, ...)", -- 2
        "    local a = res(\"a\") @ lifetime.scope", -- 3
        "    if how then", -- 4
        "        local b = res(\"b\") @ lifetime.scope", -- 5
        "        while true do", -- 6
        "            if how == 1 then return b.name, a.name, nil end", -- 7
        "            return ...", -- 8
        "        end", -- 9
        "    end", -- 10
        "    return", -- 11
        "end", -- 12
        "return f" -- 13
    }, "\n")
    local output = build(source)
    test.assert_true(output:find("local __r1, __r2, __r3 = b.name, a.name, nil; __lt_exit(__s1, \"c.lt:7\"); __lt_exit(__s2, \"c.lt:7\"); return __r1, __r2, __r3", 1, true), output)
    local log = {}
    local f = run(output, "c.lt", logger(log))
    local function pack(...)
        return {n = select("#", ...), ...}
    end
    test.assert_deep_eq(pack(f(1)), {n = 3, "b", "a"})
    test.assert_deep_eq(log, {"b anchor", "a anchor"})
    log[1], log[2] = nil, nil
    test.assert_deep_eq(pack(f(2, nil, false, nil)), {n = 3, nil, false})
    test.assert_deep_eq(log, {"b anchor", "a anchor"})
    log[1], log[2] = nil, nil
    test.assert_deep_eq(pack(f(nil)), {n = 0})
    test.assert_deep_eq(log, {"a anchor"})
    -- A `return` that leaves no block with a record is left alone.
    test.assert_eq(build("local function g() return 1 end\ndo x @ lifetime.scope end"),
        SCOPE .. " local function g() return 1 end\ndo local __s1 = __lt_enter(\"c.lt:2\"); __lt_attach(x, false, __s1) __lt_exit(__s1, \"c.lt:2\"); end")
end)

test.case("break: the epilogues up to the loop body, innermost first", function()
    -- docs/04-transpiler.md, "Blocks", **`break`**.
    local source = table.concat({
        "local res = ...", -- 1
        "for i = 1, 3 do", -- 2
        "    local a = res(\"a\" .. i) @ lifetime.scope", -- 3
        "    do", -- 4
        "        local b = res(\"b\" .. i) @ lifetime.scope", -- 5
        "        if i == 2 then break end", -- 6
        "    end", -- 7
        "end" -- 8
    }, "\n")
    local output = build(source)
    test.assert_true(output:find("if i == 2 then __lt_exit(__s1, \"c.lt:6\"); __lt_exit(__s2, \"c.lt:6\"); break end", 1, true), output)
    local log = {}
    run(output, "c.lt", logger(log))
    test.assert_deep_eq(log, {"b1 anchor", "a1 anchor", "b2 anchor", "a2 anchor"})
    -- A `break` from a loop inside the block leaves no record of it.
    output = build("do\n    local a = {} @ lifetime.scope\n    while true do break end\nend")
    test.assert_true(output:find("while true do break end", 1, true), output)
end)

test.case("repeat: the condition sees the body's scope, then the epilogue runs", function()
    -- The condition is in the body's block (Lua 5.1 manual, §2.4.4), so it
    -- is evaluated before the iteration's scope ends.
    local source = table.concat({
        "local res, log = ...", -- 1
        "local n = 0", -- 2
        "repeat", -- 3
        "    n = n + 1", -- 4
        "    local r = res(\"r\" .. n) @ lifetime.scope", -- 5
        "until (function() log[#log + 1] = \"until \" .. r.name; return n == 2 end)()", -- 6
        "return n" -- 7
    }, "\n")
    local output = build(source)
    test.assert_true(output:find("\nlocal __u = (function()", 1, true), output)
    test.assert_true(output:find("; __lt_exit(__s1, \"c.lt:6\"); until __u\n", 1, true), output)
    local log = {}
    test.assert_eq(run(output, "c.lt", logger(log), log), 2)
    test.assert_deep_eq(log, {"until r1", "r1 anchor", "until r2", "r2 anchor"})
    -- A body that ends with `break` has no fall-through: `until` as written.
    output = build("repeat\n    local r = {} @ lifetime.scope\n    break\nuntil x")
    test.assert_true(output:find("__lt_exit(__s1, \"c.lt:3\"); break\nuntil x", 1, true), output)
end)

test.case("if, elseif and else blocks end at the token that closes them", function()
    local output = build("if a then\n    x @ lifetime.scope\nelseif b then\n    y @ lifetime.scope\nelse\n    z @ lifetime.scope\nend")
    test.assert_true(output:find("if a then local __s1 = __lt_enter(\"c.lt:3\");", 1, true), output)
    test.assert_true(output:find("__lt_exit(__s1, \"c.lt:3\"); elseif b then local __s2 = __lt_enter(\"c.lt:5\");", 1, true), output)
    test.assert_true(output:find("__lt_exit(__s2, \"c.lt:5\"); else local __s3 = __lt_enter(\"c.lt:7\");", 1, true), output)
    test.assert_eq(output:sub(-#"__lt_exit(__s3, \"c.lt:7\"); end"), "__lt_exit(__s3, \"c.lt:7\"); end")
end)

test.case("goto: the epilogues of the blocks it leaves; a trailing label stays last", function()
    -- docs/04-transpiler.md, "Blocks", **`goto` (LuaJIT)**. A label at the
    -- end of a block is where LuaJIT lets a `goto` jump over a local, so
    -- the epilogue goes before it and a jump to it runs the epilogue
    -- first, with the position of the block's end.
    local source = table.concat({
        "local res = ...", -- 1
        "for i = 1, 3 do", -- 2
        "    local a = res(\"a\" .. i) @ lifetime.scope", -- 3
        "    if i == 2 then goto continue end", -- 4
        "    local b = res(\"b\" .. i) @ lifetime.scope", -- 5
        "    ::continue::", -- 6
        "end", -- 7
        "do", -- 8
        "    local c = res(\"c\") @ lifetime.scope", -- 9
        "    do", -- 10
        "        local d = res(\"d\") @ lifetime.scope", -- 11
        "        goto out", -- 12
        "    end", -- 13
        "end", -- 14
        "::out::" -- 15
    }, "\n")
    local output = build(source)
    test.assert_true(output:find("if i == 2 then __lt_exit(__s1, \"c.lt:7\"); goto continue end", 1, true), output)
    test.assert_true(output:find("__lt_exit(__s1, \"c.lt:7\"); ::continue::\nend", 1, true), output)
    test.assert_true(output:find("__lt_exit(__s2, \"c.lt:12\"); __lt_exit(__s3, \"c.lt:12\"); goto out", 1, true), output)
    -- A jump inside the block, to a label it encloses, leaves nothing.
    test.assert_true(build("do\n    x @ lifetime.scope\n    goto l\n    ::l::\n    f()\nend"):find("\n    goto l\n", 1, true))
    if jit then
        local log = {}
        run(output, "c.lt", logger(log))
        test.assert_deep_eq(log, {"b1 anchor", "a1 anchor", "a2 anchor", "b3 anchor", "a3 anchor", "d anchor", "c anchor"})
    end
end)

test.case("a goto into a block with a record is a compile error", function()
    -- "A `goto` into a block that needs a record is a compile error
    -- ("jumps into the scope of a lifetime")."
    test.assert_error(function()
        build("goto x\ndo\n    do\n        ::x::\n    end\n    y @ lifetime.scope\nend")
    end, "c.lt:1: <goto x> jumps into the scope of a lifetime")
    -- A label nobody can see is LuaJIT's to report when no record is in the
    -- way.
    test.assert_true(build("goto x\ndo ::x:: end\ndo y @ lifetime.scope end"):find("goto x", 1, true))
end)

test.case("error() on line N is reported at line N through the generated code", function()
    local source = table.concat({
        "local res = ...", -- 1
        "local a = res(\"a\") @ lifetime.scope", -- 2
        "local h = function() end", -- 3
        "    !@ (a,", -- 4
        "        lifetime.scope)", -- 5
        "do", -- 6
        "    local b = {} @ a", -- 7
        "    if b then error(\"boom\") end", -- 8
        "end" -- 9
    }, "\n")
    local output = build(source, "examples/x.lt")
    test.assert_eq(count_lines(output), count_lines(source))
    local log = {}
    local ok, message = pcall(run, output, "examples/x.lt", logger(log))
    test.assert_false(ok)
    test.assert_eq(message, "examples/x.lt:8: boom")
    -- The runtime's own errors name the line of the operator's statement.
    message = select(2, pcall(run, build("local x = 1\n\nlocal z\nlocal y = {} @ z", "examples/y.lt"), "examples/y.lt"))
    test.assert_eq(message, "examples/y.lt:4: attempt to anchor to a nil value")
    message = select(2, pcall(run, build("local x = 1\nlocal h = 5 !@ lifetime.scope", "examples/y.lt"), "examples/y.lt"))
    test.assert_eq(message, "examples/y.lt:2: attempt to defer a number value")
end)

test.case("every example builds to a chunk that loads, with its lines", function()
    local p = io.popen("ls examples/*.lt 2>/dev/null")
    local n = 0
    for path in p:lines() do
        local source = without_shebang(read_file(path))
        local output = build(source, path)
        test.assert_eq(count_lines(output), count_lines(source), path)
        assert(loadstring(output, "=" .. path), path)
        n = n + 1
    end
    p:close()
    test.assert_true(n >= 7, n .. " examples")
end)

test.case("generated code never runs into a following statement that starts with (", function()
    -- Lua 5.1 refuses a call's `)` or a name at the end of a line followed
    -- by `(` ("ambiguous syntax (function call x new statement)"); the
    -- parser takes `x @ (a, b)` and `until n >= 2` as whole, so the
    -- generated `)` and `until __u` must be kept apart from a next line
    -- starting with `(`, and nothing else gets a `;`.
    local sources = {
        "local a, b = {}, {}\nlocal x = {} @ (a, b)\n(print)(1)",
        "local a = {}\nlocal f = function() end !@ (a, a)\n(print)(2)",
        "local n = 0\nrepeat\n    n = n + 1\n    local r = {} @ lifetime.scope\nuntil n >= 2\n(print)(3)"
    }
    for _, source in ipairs(sources) do
        local output = build(source)
        test.assert_true(loadstring(output, "=c.lt"), output)
        test.assert_eq(count_lines(output), count_lines(source))
    end
    test.assert_eq(build("local a = {}\nx = {} @ (a, a)\n(f)()"), ATTACH .. " local a = {}\nx = __lt_attach({}, false, a, a);\n(f)()")
    test.assert_eq(build("local a = {}\nx = {} @ (a, a)\nf()"), ATTACH .. " local a = {}\nx = __lt_attach({}, false, a, a)\nf()")
end)
