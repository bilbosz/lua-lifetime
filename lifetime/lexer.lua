-- lifetime/lexer.lua: the lexer.
--
-- Lua 5.1 tokens (the reference manual's §2.1, `llex.c`) plus, from task
-- 005, `@` and `!@` of docs/04-transpiler.md, "Grammar". Exports
-- `tokenize(source, chunkname [, deferred])`, returning an array of tokens
-- and ending with one token of type "eof".
--
-- A token is a table {type, value, line}:
--
--   type    "name", "keyword", "number", "string", "symbol", "eof", and
--           "error" (deferred mode only, see below)
--   value   names, keywords and symbols: their text; numbers: the number;
--           strings: the decoded contents; eof: "<eof>"
--   line    the line the token starts on
--
-- Numbers and strings also carry `raw`, their spelling in the source, so
-- that the emitter writes them back exactly as written. A string that
-- spans lines also carries `end_line`, the line it ends on: Lua attaches a
-- token to the line where the lexer stands after reading it, so syntax
-- errors near it name `end_line` (the parser uses it).
--
-- A malformed token raises `chunkname:line: <message> [near '<text>']` in
-- the wording of Lua 5.1's `llex.c`. With `deferred` set, the lexer stops
-- at a malformed token and appends a token {type = "error", value =
-- <message>, line} instead of raising; the parser raises the message when
-- it reaches that token, so that a syntax error earlier in the chunk is
-- reported first, in the order Lua reports them (lua_load reads tokens
-- lazily).
--
-- Where Lua 5.1 and LuaJIT disagree at the lexical level and the manual
-- does not decide, the lexer accepts the union and leaves the
-- interpreter to reject what it does not accept when it loads the output,
-- at the same position, since the emitter keeps every token on its line:
-- `[[` inside a level-0 long string (Lua 5.1's LUA_COMPAT_LSTR error) and
-- unknown escapes such as `\q` (LuaJIT's "invalid escape sequence") pass.

local lexer = {}

local byte, char, sub, find, match, gsub, rep = string.byte, string.char, string.sub, string.find, string.match, string.gsub, string.rep
local concat = table.concat

-- The reserved words of Lua 5.1 (manual §2.1). The extension adds none
-- (docs/04-transpiler.md, "Grammar": "Reserved words: none added").
local KEYWORDS = {}
for word in ("and break do else elseif end false for function if in local nil not or repeat return then true until while"):gmatch("%a+") do
    KEYWORDS[word] = true
end
lexer.KEYWORDS = KEYWORDS

-- The escapes of manual §2.1 that stand for one control character.
local ESCAPES = {
    [97] = "\a",
    [98] = "\b",
    [102] = "\f",
    [110] = "\n",
    [114] = "\r",
    [116] = "\t",
    [118] = "\v"
}

local NL, CR = 10, 13

-- Count line breaks the way `llex.c`'s inclinenumber does: `\n`, `\r`,
-- `\n\r` and `\r\n` are one break each, `\n\n` and `\r\r` two.
local function count_newlines(s)
    local n, i = 0, 1
    while true do
        local p = find(s, "[\n\r]", i)
        if not p then
            return n
        end
        n = n + 1
        local c, d = byte(s, p, p + 1)
        if (d == NL or d == CR) and d ~= c then
            p = p + 1
        end
        i = p + 1
    end
end
lexer.count_newlines = count_newlines

-- The contents of a long bracket as Lua reads them: every line break
-- sequence becomes "\n".
local function normalize_newlines(s)
    if not find(s, "\r", 1, true) then
        return s
    end
    return (gsub(s, "[\n\r]+", function(run)
        return rep("\n", count_newlines(run))
    end))
end

-- Raised in deferred mode once the error token is in place.
local STOP = {}

-- The lexer proper. Appends to `tokens`; raises on a malformed token, or
-- in deferred mode appends the error token and raises STOP.
local function scan(source, chunkname, tokens, deferred)
    local pos, line, n = 1, 1, 0

    local function fail(message, near)
        if near then
            message = message .. " near '" .. near .. "'"
        end
        message = chunkname .. ":" .. line .. ": " .. message
        if deferred then
            tokens[n + 1] = {type = "error", value = message, line = line}
            error(STOP)
        end
        error(message, 0)
    end

    local function push(type, value, raw)
        n = n + 1
        tokens[n] = {type = type, value = value, line = line, raw = raw}
    end

    -- A long bracket whose opening `[`, `=`s, `[` ends at `open_end`.
    -- Returns the contents and moves `pos` and `line` past the closing
    -- bracket.
    local function long_bracket(open_end, level, what)
        local i = open_end + 1
        -- A line break right after the opening bracket is skipped.
        local c = byte(source, i)
        if c == NL or c == CR then
            local d = byte(source, i + 1)
            i = i + (((d == NL or d == CR) and d ~= c) and 2 or 1)
            line = line + 1
        end
        local close = "]" .. rep("=", level) .. "]"
        local p = find(source, close, i, true)
        if not p then
            line = line + count_newlines(sub(source, i))
            fail("unfinished long " .. what, "<eof>")
        end
        local contents = sub(source, i, p - 1)
        line = line + count_newlines(contents)
        pos = p + #close
        return contents
    end

    -- A quoted string opened by `quote` at `pos` (llex.c, read_string).
    local function quoted(quote)
        local start, start_line = pos, line
        local stop = quote == 34 and '[\\"\n\r]' or "[\\'\n\r]"
        local parts, np = {}, 0
        local i = pos + 1
        while true do
            local p = find(source, stop, i)
            if not p then
                fail("unfinished string", "<eof>")
            end
            np = np + 1
            parts[np] = sub(source, i, p - 1)
            local c = byte(source, p)
            if c == quote then
                pos = p + 1
                break
            elseif c == NL or c == CR then
                fail("unfinished string", char(quote) .. concat(parts))
            end
            -- A backslash (manual §2.1).
            local e = byte(source, p + 1)
            np = np + 1
            if e == nil then
                fail("unfinished string", "<eof>")
            elseif ESCAPES[e] then
                parts[np] = ESCAPES[e]
                i = p + 2
            elseif e == NL or e == CR then
                parts[np] = "\n"
                local f = byte(source, p + 2)
                i = p + (((f == NL or f == CR) and f ~= e) and 3 or 2)
                line = line + 1
            elseif e >= 48 and e <= 57 then
                local digits = match(source, "^%d%d?%d?", p + 1)
                local code = tonumber(digits)
                if code > 255 then
                    parts[np] = nil
                    fail("escape sequence too large", char(quote) .. concat(parts))
                end
                parts[np] = char(code)
                i = p + 1 + #digits
            else
                -- `\\`, `\"`, `\'` and, in Lua 5.1, any other character.
                parts[np] = char(e)
                i = p + 2
            end
        end
        n = n + 1
        local token = {type = "string", value = concat(parts), line = start_line, raw = sub(source, start, pos - 1)}
        if line ~= start_line then
            token.end_line = line
        end
        tokens[n] = token
    end

    -- A numeral starting at `pos` (llex.c, read_numeral): digits and dots,
    -- an optional exponent sign, then any letters, digits and `_`; what
    -- Lua's own conversion rejects is a malformed number.
    local function numeral()
        local _, e = find(source, "^[0-9.]*", pos)
        local c = byte(source, e + 1)
        if c == 69 or c == 101 then
            e = e + 1
            c = byte(source, e + 1)
            if c == 43 or c == 45 then
                e = e + 1
            end
        end
        _, e = find(source, "^[A-Za-z0-9_]*", e + 1)
        local raw = sub(source, pos, e)
        local value = tonumber(raw)
        if not value then
            fail("malformed number", raw)
        end
        push("number", value, raw)
        pos = e + 1
    end

    while true do
        local c = byte(source, pos)
        if c == nil then
            break
        elseif c == NL or c == CR then
            local d = byte(source, pos + 1)
            pos = pos + (((d == NL or d == CR) and d ~= c) and 2 or 1)
            line = line + 1
        elseif c == 32 or c == 9 or c == 11 or c == 12 then
            local _, e = find(source, "^[ \t\v\f]+", pos)
            pos = e + 1
        elseif (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or c == 95 then
            local _, e = find(source, "^[A-Za-z0-9_]*", pos + 1)
            local word = sub(source, pos, e)
            push(KEYWORDS[word] and "keyword" or "name", word)
            pos = e + 1
        elseif c >= 48 and c <= 57 then
            numeral()
        elseif c == 34 or c == 39 then
            quoted(c)
        elseif c == 45 then -- `-` or a comment
            if byte(source, pos + 1) == 45 then
                local level = match(source, "^%[(=*)%[", pos + 2)
                if level then
                    long_bracket(pos + 3 + #level, #level, "comment")
                else
                    pos = find(source, "[\n\r]", pos + 2) or #source + 1
                end
            else
                push("symbol", "-")
                pos = pos + 1
            end
        elseif c == 91 then -- `[` or a long string
            local _, e = find(source, "^=*", pos + 1)
            local level = e - pos
            if byte(source, e + 1) == 91 then
                local start, start_line = pos, line
                local value = normalize_newlines(long_bracket(e + 1, level, "string"))
                n = n + 1
                local token = {type = "string", value = value, line = start_line, raw = sub(source, start, pos - 1)}
                if line ~= start_line then
                    token.end_line = line
                end
                tokens[n] = token
            elseif level == 0 then
                push("symbol", "[")
                pos = pos + 1
            else
                fail("invalid long string delimiter", "[" .. rep("=", level))
            end
        elseif c == 61 or c == 60 or c == 62 or c == 126 then -- `=` `<` `>` `~`, each optionally followed by `=`
            if byte(source, pos + 1) == 61 then
                push("symbol", sub(source, pos, pos + 1))
                pos = pos + 2
            else
                push("symbol", char(c))
                pos = pos + 1
            end
        elseif c == 46 then -- `.`, `..`, `...` or a numeral
            local d = byte(source, pos + 1)
            if d == 46 then
                if byte(source, pos + 2) == 46 then
                    push("symbol", "...")
                    pos = pos + 3
                else
                    push("symbol", "..")
                    pos = pos + 2
                end
            elseif d and d >= 48 and d <= 57 then
                numeral()
            else
                push("symbol", ".")
                pos = pos + 1
            end
        else
            -- Every other character is a token of its own, as in llex.c:
            -- the operators and punctuation of §8, and anything else (such
            -- as `@` and `!`), which the parser reports as unexpected.
            push("symbol", char(c))
            pos = pos + 1
        end
    end
    n = n + 1
    tokens[n] = {type = "eof", value = "<eof>", line = line}
end

-- Tokenize `source`. A malformed token raises `chunkname:line: <message>`,
-- or with `deferred` ends the array with an "error" token.
function lexer.tokenize(source, chunkname, deferred)
    local tokens = {}
    if not deferred then
        scan(source, chunkname, tokens, false)
        return tokens
    end
    local ok, err = pcall(scan, source, chunkname, tokens, true)
    if not ok and err ~= STOP then
        error(err, 0)
    end
    return tokens
end

return lexer
