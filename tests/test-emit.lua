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

-- Every Lua source of this repository: the transpiler, the runtime, the
-- tests, the command and the examples.
local function corpus()
    local paths = {}
    local p = io.popen("ls lifetime/*.lua tests/*.lua tests/lib/*.lua examples/*.lt bin/lifetime 2>/dev/null")
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

test.case("the extension's nodes come back in their spelling, every token on its line", function()
    -- Task 005: until task 006 generates code, the emitter writes `@`,
    -- `!@`, `lifetime.scope`, `goto` and labels back as written; the round
    -- trip proves that the parser records the line of every token.
    local ast = parse(chunks.EXTENDED)
    local output = emit.emit(ast)
    test.assert_deep_eq(parse(output), ast)
    test.assert_deep_eq(lexer.tokenize(output, "t"), lexer.tokenize(chunks.EXTENDED, "t"))
    test.assert_eq(round_trip("local h = f !@ ( a ,lifetime.scope ) @ b\nx @ (t) .owner"), "local h = f !@ (a, lifetime.scope) @ b\nx @ (t).owner")
    -- Chained statements (docs/04-transpiler.md, "Grammar"), over lines.
    local chained = "f !@ a @ b\nfunction() end !@ a\n  @ (b,\n  lifetime.scope) !@ c\nx\n@\nlifetime\n.\nscope\n@\nd\n"
    ast = parse(chained)
    output = emit.emit(ast)
    test.assert_deep_eq(parse(output), ast)
    test.assert_deep_eq(lexer.tokenize(output, "t"), lexer.tokenize(chained, "t"))
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
