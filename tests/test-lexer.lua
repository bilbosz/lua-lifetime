-- tests/test-lexer.lua: lifetime/lexer.lua (task 001). The tokens of Lua
-- 5.1 (manual §2.1, §8) with their lines, and malformed tokens reported in
-- the wording and at the line of Lua 5.1's llex.c.
local test = require("tests.lib.test")
local lexer = require("lifetime.lexer")

local function T(type, value, line, raw, end_line)
    return {type = type, value = value, line = line, raw = raw, end_line = end_line}
end

local function K(value, line)
    return T("keyword", value, line)
end

local function S(value, line)
    return T("symbol", value, line)
end

local function N(value, raw, line)
    return T("number", value, line, raw)
end

local function assert_raises(source, expected)
    local ok, err = pcall(lexer.tokenize, source, "t")
    test.assert_false(ok, "expected an error for " .. string.format("%q", source))
    test.assert_eq(err, expected)
end

test.suite("lexer")

test.case("every token class, token by token with lines", function()
    local source = table.concat({
        "local x_1 = nil and true or false not", -- 1
        "0 3 3.0 3.1416 314.16e-2 0.31416E1 0xff 0x56 .5 5. 1e10 2E+3", -- 2
        [['single' "double" '\a\b\f\n\r\t\v\\\"\'' "\65\066\0067"]], -- 3
        "[[long]] [==[", -- 4
        "level ]] two]==] -- a comment", -- 5
        "--[[ a long", -- 6
        "comment ]] --[=[ x ]=] + - * / % ^ #", -- 7
        "== ~= <= >= < > = ( ) { } [ ] ; : , . .. ...", -- 8
        [["line\]], -- 9
        [[break" @ ! if elseif else then end while do for in repeat until]], -- 10
        "function return break", -- 11
        "" -- 12: <eof>
    }, "\n")
    local expected = {
        K("local", 1), T("name", "x_1", 1), S("=", 1), K("nil", 1), K("and", 1), K("true", 1), K("or", 1), K("false", 1), K("not", 1),
        N(0, "0", 2), N(3, "3", 2), N(3, "3.0", 2), N(3.1416, "3.1416", 2), N(3.1416, "314.16e-2", 2), N(3.1416, "0.31416E1", 2), N(255, "0xff", 2),
        N(86, "0x56", 2), N(0.5, ".5", 2), N(5, "5.", 2), N(1e10, "1e10", 2), N(2000, "2E+3", 2),
        T("string", "single", 3, "'single'"), T("string", "double", 3, '"double"'), T("string", "\a\b\f\n\r\t\v\\\"'", 3, [['\a\b\f\n\r\t\v\\\"\'']]),
        T("string", "AB\0067", 3, [["\65\066\0067"]]),
        T("string", "long", 4, "[[long]]"), T("string", "level ]] two", 4, "[==[\nlevel ]] two]==]", 5),
        S("+", 7), S("-", 7), S("*", 7), S("/", 7), S("%", 7), S("^", 7), S("#", 7),
        S("==", 8), S("~=", 8), S("<=", 8), S(">=", 8), S("<", 8), S(">", 8), S("=", 8), S("(", 8), S(")", 8), S("{", 8), S("}", 8), S("[", 8),
        S("]", 8), S(";", 8), S(":", 8), S(",", 8), S(".", 8), S("..", 8), S("...", 8),
        T("string", "line\nbreak", 9, '"line\\\nbreak"', 10), S("@", 10), S("!", 10), K("if", 10), K("elseif", 10), K("else", 10), K("then", 10),
        K("end", 10), K("while", 10), K("do", 10), K("for", 10), K("in", 10), K("repeat", 10), K("until", 10),
        K("function", 11), K("return", 11), K("break", 11),
        T("eof", "<eof>", 12)
    }
    local tokens = lexer.tokenize(source, "t")
    for i = 1, math.max(#tokens, #expected) do
        test.assert_deep_eq(tokens[i], expected[i], "token " .. i)
    end
end)

test.case("line breaks count as Lua counts them", function()
    -- llex.c, inclinenumber: \r\n and \n\r are one break, \r\r and \n\n two.
    local tokens = lexer.tokenize("a\r\nb\n\rc\r\rd\n\ne", "t")
    local lines = {}
    for i = 1, #tokens do
        lines[i] = tokens[i].line
    end
    test.assert_deep_eq(lines, {1, 2, 3, 5, 7, 7})
end)

test.case("long brackets: first line break skipped, line breaks normalized, levels", function()
    local tokens = lexer.tokenize("x = [[\nfirst]] .. [[a\r\nb]] .. [=[]]]=] .. [[]=]]", "t")
    test.assert_deep_eq(tokens[3], T("string", "first", 1, "[[\nfirst]]", 2))
    test.assert_deep_eq(tokens[5], T("string", "a\nb", 2, "[[a\r\nb]]", 3))
    test.assert_deep_eq(tokens[7], T("string", "]]", 3, "[=[]]]=]"))
    test.assert_deep_eq(tokens[9], T("string", "]=", 3, "[[]=]]"))
    test.assert_eq(tokens[10].type, "eof")
end)

test.case("comments: short, long of any level, and `--[` that opens no long bracket", function()
    local tokens = lexer.tokenize("a --[==[ x\n]] ]==] b --[== c\nd --[[\n\n]] e -- f", "t")
    test.assert_deep_eq(tokens, {T("name", "a", 1), T("name", "b", 2), T("name", "d", 3), T("name", "e", 5), T("eof", "<eof>", 5)})
end)

test.case("decimal escapes take at most three digits", function()
    local tokens = lexer.tokenize([["\9\99\0999\255"]], "t")
    test.assert_eq(tokens[1].value, "\9\99\0999\255")
end)

test.case("`@`, and `!@` as one token when `!` is immediately followed by `@`", function()
    -- docs/04-transpiler.md, "Grammar": "The lexer produces `!@` as one
    -- token when `!` is immediately followed by `@`".
    local tokens = lexer.tokenize("x @ y !@ z!@w", "t")
    test.assert_deep_eq(tokens, {T("name", "x", 1), S("@", 1), T("name", "y", 1), S("!@", 1), T("name", "z", 1), S("!@", 1), T("name", "w", 1), T("eof", "<eof>", 1)})
    -- A lone `!` is a symbol of its own, which the parser rejects.
    tokens = lexer.tokenize("f ! @ a !\n@", "t")
    test.assert_deep_eq(tokens, {T("name", "f", 1), S("!", 1), S("@", 1), T("name", "a", 1), S("!", 1), S("@", 2), T("eof", "<eof>", 2)})
end)

test.case("`!=` is reported with a pointer to `~=`", function()
    -- docs/04-transpiler.md, "Grammar": "`!=` is reported as `unexpected
    -- symbol near '!' (use '~=' for inequality)`".
    assert_raises("if a != b then end", "t:1: unexpected symbol near '!' (use '~=' for inequality)")
    assert_raises("x = 1\n\nprint(a!=b)", "t:3: unexpected symbol near '!' (use '~=' for inequality)")
    local tokens = lexer.tokenize("x = a != b", "t", true)
    test.assert_deep_eq(tokens, {
        T("name", "x", 1), S("=", 1), T("name", "a", 1), {type = "error", value = "t:1: unexpected symbol near '!' (use '~=' for inequality)", line = 1}
    })
    -- `! =` apart is a lone `!` and an `=`.
    test.assert_deep_eq(lexer.tokenize("! =", "t"), {S("!", 1), S("=", 1), T("eof", "<eof>", 1)})
end)

test.case("`::` is one token (LuaJIT labels), `: :` two", function()
    local tokens = lexer.tokenize("::top:: a:b : :", "t")
    test.assert_deep_eq(tokens, {
        S("::", 1), T("name", "top", 1), S("::", 1), T("name", "a", 1), S(":", 1), T("name", "b", 1), S(":", 1), S(":", 1), T("eof", "<eof>", 1)
    })
end)

-- docs/05-decisions.md, "The lexer accepts LuaJIT's lexical extensions".
test.case("LuaJIT: a byte order mark and a `#` first line are skipped, lines kept", function()
    test.assert_deep_eq(lexer.tokenize("\239\187\191x", "t"), {T("name", "x", 1), T("eof", "<eof>", 1)})
    test.assert_deep_eq(lexer.tokenize("#!/usr/bin/env lifetime run\nx", "t"), {T("name", "x", 2), T("eof", "<eof>", 2)})
    test.assert_deep_eq(lexer.tokenize("\239\187\191# comment\r\n\r\nx", "t"), {T("name", "x", 3), T("eof", "<eof>", 3)})
    test.assert_deep_eq(lexer.tokenize("#", "t"), {T("eof", "<eof>", 1)})
    -- Only at the very start: elsewhere `#` is the length operator, and a
    -- byte order mark is no name.
    test.assert_deep_eq(lexer.tokenize(" #t", "t"), {S("#", 1), T("name", "t", 1), T("eof", "<eof>", 1)})
end)

test.case("LuaJIT: bytes >= 128 in names", function()
    local tokens = lexer.tokenize("local caf\195\169 = \226\128\162x_\200", "t")
    test.assert_deep_eq(tokens, {K("local", 1), T("name", "caf\195\169", 1), S("=", 1), T("name", "\226\128\162x_\200", 1), T("eof", "<eof>", 1)})
end)

test.case("LuaJIT: `\\z` before a line break skips the white space; elsewhere it is Lua 5.1's `z`", function()
    local tokens = lexer.tokenize("x = \"a\\z  \n\r\n   b\" .. 'c\\z d'", "t")
    test.assert_deep_eq(tokens[3], T("string", "ab", 1, "\"a\\z  \n\r\n   b\"", 3))
    test.assert_deep_eq(tokens[4], S("..", 3))
    test.assert_deep_eq(tokens[5], T("string", "cz d", 3, "'c\\z d'"))
    -- `\x41` and `\u{41}` are Lua 5.1 strings already, read as Lua 5.1 reads them.
    test.assert_eq(lexer.tokenize([["\x41\u{41}"]], "t")[1].value, "x41u{41}")
end)

test.case("LuaJIT: binary numerals and the suffixes LL, ULL and i", function()
    local tokens = lexer.tokenize("0b101 0B1 1LL 0x10ULL 10ull 1llu 0b11LL 1i 1.5e3I 0x10i 0b1i .5i", "t")
    local expected = {
        N(5, "0b101", 1), N(1, "0B1", 1), N(1, "1LL", 1), N(16, "0x10ULL", 1), N(10, "10ull", 1), N(1, "1llu", 1), N(3, "0b11LL", 1), N(1, "1i", 1),
        N(1500, "1.5e3I", 1), N(16, "0x10i", 1), N(1, "0b1i", 1), N(0.5, ".5i", 1), T("eof", "<eof>", 1)
    }
    test.assert_deep_eq(tokens, expected)
    -- What neither Lua 5.1 nor LuaJIT reads stays malformed, whichever
    -- interpreter runs the lexer.
    assert_raises("x = 1.5LL", "t:1: malformed number near '1.5LL'")
    assert_raises("x = 1e2ll", "t:1: malformed number near '1e2ll'")
    assert_raises("x = 0b", "t:1: malformed number near '0b'")
    assert_raises("x = 0b12", "t:1: malformed number near '0b12'")
    assert_raises("x = 5u", "t:1: malformed number near '5u'")
    assert_raises("x = 1iLL", "t:1: malformed number near '1iLL'")
end)

test.case("unfinished string", function()
    assert_raises([["abc]], "t:1: unfinished string near '<eof>'")
    assert_raises('"abc\nx', [[t:1: unfinished string near '"abc']])
    assert_raises('\n\n"abc\\\n', "t:4: unfinished string near '<eof>'")
    assert_raises('x = "\\', "t:1: unfinished string near '<eof>'")
end)

test.case("malformed number", function()
    assert_raises("x = 0x", "t:1: malformed number near '0x'")
    assert_raises("x = 3..2", "t:1: malformed number near '3..2'")
    assert_raises("\nx = 1e", "t:2: malformed number near '1e'")
    assert_raises("x = 0xG", "t:1: malformed number near '0xG'")
end)

test.case("other malformed tokens", function()
    assert_raises([[x = "ab\300"]], [[t:1: escape sequence too large near '"ab']])
    assert_raises("x = [==[ abc\n", "t:2: unfinished long string near '<eof>'")
    assert_raises("--[[ abc", "t:1: unfinished long comment near '<eof>'")
    assert_raises("x = [=a", "t:1: invalid long string delimiter near '[='")
end)

test.case("deferred: a malformed token becomes an error token", function()
    local tokens = lexer.tokenize("x = 0x", "t", true)
    test.assert_deep_eq(tokens, {T("name", "x", 1), S("=", 1), {type = "error", value = "t:1: malformed number near '0x'", line = 1}})
end)

test.case("count_newlines", function()
    test.assert_eq(lexer.count_newlines("a\r\n\n\rb\n\n\r\r"), 5) -- \r\n, \n\r, \n, \n\r, \r
    test.assert_eq(lexer.count_newlines("no breaks"), 0)
end)
