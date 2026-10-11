-- editor/luals/plugin.lua: a plugin for the Lua language server (LuaLS,
-- the sumneko.lua extension of VS Code) that lets it read `.lt` files.
--
-- The server parses Lua only. This plugin's OnSetText rewrites a `.lt`
-- file into plain Lua of the same shape before the server parses it, and
-- returns the rewrite as a list of diffs, so that the server maps every
-- position back to the source for hover, go to definition and
-- diagnostics. The rewrite is for analysis only: it is never run, and the
-- transpiler (lifetime/emit.lua) is the only thing that generates code.
--
-- The rewrite, driven by the repository's own lexer (lifetime/lexer.lua),
-- so that it reads exactly the tokens the transpiler reads:
--
--   e @ a             e or a          `@` and `!@` are postfix operators of
--   f !@ a            f or a          the lowest precedence that chain to
--                                     the left (docs/04-transpiler.md,
--                                     "Grammar"); `or` is the Lua operator
--                                     with the same shape.
--   e @ (a, b)        e or (a or b)   the list form: its commas.
--   x @ a             local _ = x or a
--                                     the statement form (stat ::=
--                                     prefixexp anchorop { anchorop } and
--                                     functiondef '!@' anchor { anchorop }):
--                                     an expression is not a statement, so
--                                     it is assigned to `_`, which the
--                                     server never reports as unused or
--                                     redefined.
--   <first token>     local lifetime = require("lifetime") <first token>
--                                     the header the transpiler emits
--                                     (docs/04-transpiler.md, "The
--                                     generated chunk header"), inserted
--                                     when the file uses an anchor or names
--                                     `lifetime`, so that `lifetime.*`
--                                     resolves to lifetime/init.lua with its
--                                     real functions and `lifetime.scope`
--                                     is the marker field the runtime has.
--
-- The statement form is told from the expression form by walking back
-- over the left operand (a prefixexp, or a function body up to its
-- `function`) and looking at the token before it: a statement starts
-- after `;`, `::`, a block keyword, or a token that ends the previous
-- statement; an expression continues after an operator, `=`, `(`, `,`,
-- `return`, `until` and the like.
--
-- When the lexer stops at a malformed token, or the tokens cannot be
-- aligned to the text, the plugin returns nothing and the server sees the
-- raw file. editor/luals/check.lua runs this rewrite over every `.lt` file
-- of the repository and checks that the result is syntactically valid Lua.
--
-- The server loads this file with `load(text, name, "t", env)` where env
-- indexes the server's globals; OnSetText is the global it looks up.
-- editor/luals/check.lua loads it the same way under Lua 5.1 and LuaJIT.

local sub, find = string.sub, string.find

-- The lexer, found relative to this file so that the plugin reads the
-- grammar of the checkout it lives in. loadfile, not require: the server
-- has a package.loaded of its own that this must not touch.
local here = (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]")) or "."
local lexer = assert(loadfile(here .. "/../../lifetime/lexer.lua"))()

local HEADER = 'local lifetime = require("lifetime") '

-- The spelling of a token in the source: names, keywords and symbols
-- carry it in `value`, numbers and strings in `raw`.
local function spelling(t)
    local ty = t.type
    if ty == "number" or ty == "string" then
        return t.raw
    end
    return t.value
end

-- Skip whitespace and comments from position p; return the position of
-- the next token. Lua 5.1's llex.c: a comment is `--` followed by a long
-- bracket, to its closing bracket, or anything else to the end of the
-- line.
local function skip(text, p)
    while true do
        local _, e = find(text, "^[ \t\n\r\v\f]+", p)
        if e then
            p = e + 1
        end
        if sub(text, p, p + 1) ~= "--" then
            return p
        end
        local _, close, eq = find(text, "^%[(=*)%[", p + 2)
        if close then
            local _, stop = find(text, "]" .. eq .. "]", close + 1, true)
            if not stop then
                return #text + 1
            end
            p = stop + 1
        else
            local nl = find(text, "[\n\r]", p + 2)
            if not nl then
                return #text + 1
            end
            p = nl
        end
    end
end

-- Give every token its byte range in text (`pos`, `stop`, inclusive) by
-- walking the text alongside the token array. Returns false when a token
-- is not found where it should be, which means the walk and the lexer
-- disagree and the rewrite must not be trusted.
local function align(tokens, text)
    local p = 1
    if sub(text, 1, 3) == "\239\187\191" then
        p = 4
    end
    if sub(text, p, p) == "#" then
        p = find(text, "[\n\r]", p) or #text + 1
    end
    for i = 1, #tokens do
        local t = tokens[i]
        local ty = t.type
        if ty == "eof" or ty == "error" then
            return true
        end
        p = skip(text, p)
        local s = spelling(t)
        if type(s) ~= "string" or sub(text, p, p + #s - 1) ~= s then
            return false
        end
        t.pos, t.stop = p, p + #s - 1
        p = p + #s
    end
    return true
end

local function is_symbol(t, v)
    return t ~= nil and t.type == "symbol" and t.value == v
end

local function is_keyword(t, v)
    return t ~= nil and t.type == "keyword" and t.value == v
end

local function is_anchorop(t)
    return t ~= nil and t.type == "symbol" and (t.value == "@" or t.value == "!@")
end

-- A token that can end a prefixexp, so that a `(`, `[`, `{` or string
-- after it is a call or an index on it.
local function ends_prefixexp(t)
    if t == nil then
        return false
    end
    local ty = t.type
    if ty == "name" or ty == "string" then
        return true
    end
    return ty == "symbol" and (t.value == ")" or t.value == "]" or t.value == "}")
end

-- tokens[i] is `)`, `]` or `}`: the index of its opener, or nil.
local function matching_open(tokens, i)
    local depth = 0
    for j = i, 1, -1 do
        local t = tokens[j]
        if t.type == "symbol" then
            local v = t.value
            if v == ")" or v == "]" or v == "}" then
                depth = depth + 1
            elseif v == "(" or v == "[" or v == "{" then
                depth = depth - 1
                if depth == 0 then
                    return j
                end
            end
        end
    end
    return nil
end

-- tokens[i] is `(`, `[` or `{`: the index of its closer, or nil.
local function matching_close(tokens, i)
    local depth = 0
    for j = i, #tokens do
        local t = tokens[j]
        if t.type == "symbol" then
            local v = t.value
            if v == "(" or v == "[" or v == "{" then
                depth = depth + 1
            elseif v == ")" or v == "]" or v == "}" then
                depth = depth - 1
                if depth == 0 then
                    return j
                end
            end
        end
    end
    return nil
end

-- tokens[i] is the last token of the left operand of an anchor operator.
-- Returns the index of the operand's first token, or nil when the
-- operand is not a prefixexp or a function (then it is no statement).
local function operand_start(tokens, i)
    if is_keyword(tokens[i], "end") then
        -- A function body: balance `end` against the keywords that take
        -- one. `while` and `for` close through their `do`.
        local depth = 0
        for j = i, 1, -1 do
            local t = tokens[j]
            if t.type == "keyword" then
                local v = t.value
                if v == "end" then
                    depth = depth + 1
                elseif v == "function" or v == "if" or v == "do" then
                    depth = depth - 1
                    if depth == 0 then
                        return v == "function" and j or nil
                    end
                end
            end
        end
        return nil
    end
    while true do
        local t = tokens[i]
        if t == nil then
            return nil
        end
        local ty, v = t.type, t.value
        if ty == "symbol" and (v == ")" or v == "]" or v == "}") then
            local o = matching_open(tokens, i)
            if o == nil then
                return nil
            end
            local q = tokens[o - 1]
            if tokens[o].value == "[" then
                if not ends_prefixexp(q) then
                    return nil
                end
                i = o - 1
            elseif ends_prefixexp(q) then
                i = o - 1 -- a call: `f(...)`, `f{...}`
            else
                return o -- `( exp )` or a table constructor
            end
        elseif ty == "string" then
            if ends_prefixexp(tokens[i - 1]) then
                i = i - 1 -- a call: `f"..."`
            else
                return i
            end
        elseif ty == "name" then
            local q = tokens[i - 1]
            if q ~= nil and q.type == "symbol" and (q.value == "." or q.value == ":") then
                i = i - 2
            else
                return i
            end
        else
            return i
        end
    end
end

-- Block keywords after which a statement starts.
local STATEMENT_BEFORE = {
    ["do"] = true, ["then"] = true, ["else"] = true, ["repeat"] = true, ["end"] = true,
    ["break"] = true, ["true"] = true, ["false"] = true, ["nil"] = true
}

-- Whether a statement starts after token p (nil: the start of the chunk).
local function statement_after(p)
    if p == nil then
        return true
    end
    local ty, v = p.type, p.value
    if ty == "name" or ty == "number" or ty == "string" then
        return true
    end
    if ty == "keyword" then
        return STATEMENT_BEFORE[v] == true
    end
    return ty == "symbol" and (v == ";" or v == ")" or v == "]" or v == "}" or v == "::" or v == "...")
end

-- The rewrite of `text`: an array of diffs {start, finish, text} over
-- byte offsets (inclusive, 1-based), or nil when there is nothing to do
-- or the text cannot be read.
local function rewrite(text)
    local tokens = lexer.tokenize(text, "=lt", true)
    if not align(tokens, text) then
        return nil
    end
    local prefix, replace = {}, {}
    local n = #tokens
    local uses = false
    local first
    for i = 1, n do
        local t = tokens[i]
        if t.pos == nil then
            break
        end
        first = first or i
        if t.type == "name" and t.value == "lifetime" then
            uses = true
        elseif is_anchorop(t) then
            uses = true
            replace[i] = " or "
            -- The list form: `(` after the operator, its commas at depth 1.
            if is_symbol(tokens[i + 1], "(") then
                local close = matching_close(tokens, i + 1)
                if close ~= nil then
                    local depth = 0
                    for j = i + 2, close - 1 do
                        local u = tokens[j]
                        if u.type == "symbol" then
                            local v = u.value
                            if v == "(" or v == "[" or v == "{" then
                                depth = depth + 1
                            elseif v == ")" or v == "]" or v == "}" then
                                depth = depth - 1
                            elseif v == "," and depth == 0 then
                                replace[j] = " or "
                            end
                        end
                    end
                end
            end
            -- The statement form: the chain's first operator whose
            -- operand begins a statement.
            if i > 1 and not is_anchorop(tokens[i - 1]) then
                local start = operand_start(tokens, i - 1)
                if start ~= nil and not is_anchorop(tokens[start - 1]) and statement_after(tokens[start - 1]) then
                    prefix[start] = "local _ = "
                end
            end
        end
    end
    if not uses or first == nil then
        return nil
    end
    local diffs = {}
    local header_at = tokens[first].pos
    if prefix[first] == nil and replace[first] == nil then
        diffs[1] = {start = header_at, finish = header_at - 1, text = HEADER}
    else
        prefix[first] = HEADER .. (prefix[first] or "")
    end
    for i = 1, n do
        local p, r = prefix[i], replace[i]
        if p ~= nil or r ~= nil then
            local t = tokens[i]
            diffs[#diffs + 1] = {start = t.pos, finish = t.stop, text = (p or "") .. (r or spelling(t))}
        end
    end
    return diffs
end

-- The server's hook. `uri` is the file's URI, `text` its contents.
function OnSetText(uri, text)
    if sub(uri, -3) ~= ".lt" then
        return nil
    end
    local ok, diffs = pcall(rewrite, text)
    if ok then
        return diffs
    end
    if type(log) == "table" and type(log.warn) == "function" then
        log.warn("editor/luals/plugin.lua: " .. tostring(diffs))
    end
    return nil
end

-- For editor/luals/check.lua.
return {rewrite = rewrite}
