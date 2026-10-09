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

test.case("@ and ! are tokens of their own for the parser to reject", function()
    local tokens = lexer.tokenize("x @ y !@ z", "t")
    test.assert_deep_eq(tokens, {T("name", "x", 1), S("@", 1), T("name", "y", 1), S("!", 1), S("@", 1), T("name", "z", 1), T("eof", "<eof>", 1)})
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
