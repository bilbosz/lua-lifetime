-- lifetime/parser.lua: the parser.
--
-- A recursive-descent parser for the grammar of docs/04-transpiler.md,
-- "Grammar": Lua 5.1 as in `lparser.c` and the manual's §8, plus `@` with
-- the list form, the hook operator `!@`, `lifetime.scope` as an anchor,
-- and LuaJIT's `goto` and labels. Exports `parse(tokens, chunkname)`,
-- taking the tokens of lifetime/lexer.lua and returning the AST of the
-- chunk, a Block. A syntax error raises `chunkname:line: <message> near
-- '<token>'` in the wording of Lua 5.1's `lparser.c`, at the line Lua
-- names; the extension's own errors take the same shape.
--
-- The AST is plain tables. Every node has `tag` and `line`, the line its
-- first token starts on. Every node that owns tokens of its own (keywords,
-- punctuation, operators, the names of fields and methods) also has
-- `lines`, the lines of those tokens in source order, so that the emitter
-- can put every token back on its line (docs/04-transpiler.md, "Pipeline":
-- "The emitter keeps every statement on its source line"; keeping every
-- token there keeps the line information of the compiled chunk, and with it
-- every error position and traceback, identical). A node built by later
-- stages may omit `lines`; its tokens then follow on the current line.
--
-- Nodes, with the tokens recorded in `lines`:
--
--   Block        [1..n] = statements                      (none; the chunk: <eof>)
--   Local        names = {Id}, exprs = {expr}             local , = ,
--   LocalFunction name = Id, func = Function              local
--   FunctionStat target = Id|Member, method = string|nil, func = Function
--                                                         : method
--   Set          targets = {expr}, exprs = {expr}         , = ,
--   CallStat     call = Call|Invoke                       (none)
--   Do           body                                     do end
--   While        cond, body                               while do end
--   Repeat       body, cond                               repeat until
--   If           conds = {expr}, blocks = {Block}, else_block = Block|nil
--                                                         if then {elseif then} [else] end
--   NumericFor   var = Id, start, limit, step|nil, body   for = , [,] do end
--   GenericFor   vars = {Id}, exprs, body                 for , in , do end
--   Return       exprs                                    return ,
--   Break                                                 break
--   AnchorStat   expr = Anchor                            (none)
--   HookStat     expr = Hook                              (none)
--   Goto         name                                     goto name
--   Label        name                                     :: name ::
--
--   Nil True False Vararg                                 (the token: `line`)
--   Number       value, raw                               (the token)
--   String       value, raw                               (the token)
--   Id           name                                     (the token)
--   Function     params = {Id}, is_vararg, is_method|nil, body
--                                                         function ( , [...] ) end
--   Table        fields, seps = {"," | ";"}               { seps }
--     PosField   value                                    (none)
--     NameField  name, value                              name =
--     KeyField   key, value                               [ ] =
--   Member       obj, name                                . name
--   Index        obj, key                                 [ ]
--   Call         func, args, sugar                        ( , )  (none when sugar)
--   Invoke       obj, method, args, sugar                 : method ( , )
--   Paren        expr                                     ( )
--   BinOp        op, left, right                          op
--   UnOp         op, operand                              op
--   Anchor       expr, anchors = {item}, list|nil         @ [( , )]
--   Hook         expr, anchors = {item}, list|nil, name|nil
--                                                         !@ [( , )]
--     ScopeAnchor                                         lifetime . scope
--
-- `e @ a` and `e !@ a` (docs/04-transpiler.md, "Grammar"): `expr` is the
-- operand on the left, `anchors` the anchor items in source order, each an
-- expression or a ScopeAnchor, the spelling `lifetime.scope` in anchor
-- position. `list` marks the parenthesised list form, whose `(`, commas
-- and `)` are the node's own tokens; a one-element list holds its item
-- (`x @ (a)` is `x @ a`, docs/02-semantics.md, "Acquiring a lifetime"). A
-- Hook bound to a name carries it in `name` (docs/02-semantics.md, "Named
-- hooks").
--
-- `sugar` marks a call whose single argument is a string or a table
-- constructor written without parentheses (`f"x"`, `f{...}`). A statement
-- followed by `;` has `semi`, the line of the `;`.

local parser = {}

-- Under LuaJIT, run this module in the interpreter: a recursive walk
-- with a dispatch per node makes the trace compiler abort and flush its
-- machine code over and over, which made a build several times slower
-- than with no compiler at all (task 001, handoff). The number is the
-- benchmark `build/lifetime-largest` in bench/bench-build.lua, `cli.build`
-- on the largest file under lifetime/ (`make bench`): about 4 ms with
-- this call under LuaJIT, about 30 ms without (task 010). Lua 5.1 has no
-- `jit`.
if jit then
    jit.off(true, true)
end

local byte, sub, match, format = string.byte, string.sub, string.match, string.format

-- Binary operator priorities, left and right (lparser.c, `priority`).
local LEFT = {
    ["or"] = 1,
    ["and"] = 2,
    ["<"] = 3,
    [">"] = 3,
    ["<="] = 3,
    [">="] = 3,
    ["~="] = 3,
    ["=="] = 3,
    [".."] = 5,
    ["+"] = 6,
    ["-"] = 6,
    ["*"] = 7,
    ["/"] = 7,
    ["%"] = 7,
    ["^"] = 10
}
local RIGHT = {
    ["or"] = 1,
    ["and"] = 2,
    ["<"] = 3,
    [">"] = 3,
    ["<="] = 3,
    [">="] = 3,
    ["~="] = 3,
    ["=="] = 3,
    [".."] = 4,
    ["+"] = 6,
    ["-"] = 6,
    ["*"] = 7,
    ["/"] = 7,
    ["%"] = 7,
    ["^"] = 9
}
local UNARY_PRIORITY = 8

-- The text Lua shows for a token in "near '...'" (llex.c, txtToken): the
-- spelling of names and numbers, a string with its delimiters around the
-- decoded contents, `char(N)` for a control character.
local function near_text(t)
    local ty = t.type
    if ty == "number" then
        return t.raw
    elseif ty == "string" then
        local open = sub(t.raw, 1, 1)
        if open == "[" then
            local level = match(t.raw, "^%[(=*)%[")
            return "[" .. level .. "[" .. t.value .. "]" .. level .. "]"
        end
        return open .. t.value .. open
    elseif ty == "symbol" and #t.value == 1 then
        local b = byte(t.value)
        if b < 32 or b == 127 then
            return "char(" .. b .. ")"
        end
    end
    return t.value
end

function parser.parse(tokens, chunkname)
    local pos, tok = 1, tokens[1]
    -- The function being parsed: is it vararg, how many loops enclose the
    -- current statement (lparser.c, FuncState and BlockCnt).
    local fs = {is_vararg = true, loops = 0}
    -- The index of the token a table constructor looked at after a Name
    -- that turned out to start an expression (see `constructor`).
    local looked_ahead

    -- Raise a syntax error near the current token, at the line Lua names:
    -- the line where the lexer stands after reading it.
    local function raise(message)
        local where = chunkname .. ":" .. (tok.end_line or tok.line) .. ": " .. message
        -- A NUL character is token 0, which llex.c's luaX_lexerror takes
        -- for "no token": Lua names nothing near it.
        if tok.value == "\0" and tok.type == "symbol" then
            error(where, 0)
        end
        error(where .. " near '" .. near_text(tok) .. "'", 0)
    end

    local function raise_expected(what)
        raise("'" .. what .. "' expected")
    end

    local function advance()
        pos = pos + 1
        tok = tokens[pos]
        if tok.type == "error" then
            error(tok.value, 0)
        end
    end

    if tok.type == "error" then
        error(tok.value, 0)
    end

    -- Is the current token the keyword or symbol `s`? A string token may
    -- hold any text, so it never matches; a name never spells a keyword
    -- or a symbol.
    local function is(s)
        return tok.value == s and tok.type ~= "string"
    end

    -- Is the current token the operator `@` or `!@`? Returns its text.
    local function anchor_operator()
        local v = tok.value
        return (v == "@" or v == "!@") and tok.type == "symbol" and v
    end

    -- Consume the keyword or symbol `s`, record its line in `lines`.
    local function check_next(s, lines)
        if not is(s) then
            raise_expected(s)
        end
        lines[#lines + 1] = tok.line
        advance()
    end

    -- Consume the closing `what` of a construct opened by `who` at line
    -- `where` (lparser.c, check_match).
    local function check_match(what, who, where, lines)
        if not is(what) then
            if where == (tok.end_line or tok.line) then
                raise_expected(what)
            else
                raise(format("'%s' expected (to close '%s' at line %d)", what, who, where))
            end
        end
        lines[#lines + 1] = tok.line
        advance()
    end

    -- Consume a name and return it.
    local function check_name()
        if tok.type ~= "name" then
            raise_expected("<name>")
        end
        local name = tok.value
        advance()
        return name
    end

    local function id()
        local line = tok.line
        return {tag = "Id", name = check_name(), line = line}
    end

    local function block_follow()
        local t = tok
        if t.type == "keyword" then
            local v = t.value
            return v == "else" or v == "elseif" or v == "end" or v == "until"
        end
        return t.type == "eof"
    end

    local block, expr, primaryexp, suffixedexp

    -- explist1: expr {',' expr}; the commas go into `lines`.
    local function explist(lines)
        local list = {expr()}
        while is(",") do
            lines[#lines + 1] = tok.line
            advance()
            list[#list + 1] = expr()
        end
        return list
    end

    -- The body of a function from `(` to `end` (lparser.c, body). `node`
    -- already holds the line of `function` in its lines; `line` is the
    -- line Lua reports an unclosed body against.
    local function body(node, line, is_method)
        local lines = node.lines
        check_next("(", lines)
        local params, is_vararg = {}, false
        if not is(")") then
            repeat
                if tok.type == "name" then
                    params[#params + 1] = id()
                elseif is("...") then
                    lines[#lines + 1] = tok.line
                    advance()
                    is_vararg = true
                else
                    raise("<name> or '...' expected")
                end
                local more = not is_vararg and is(",")
                if more then
                    lines[#lines + 1] = tok.line
                    advance()
                end
            until not more
        end
        check_next(")", lines)
        local outer = fs
        fs = {is_vararg = is_vararg, loops = 0}
        node.params, node.is_vararg = params, is_vararg
        node.is_method = is_method or nil
        node.body = block()
        fs = outer
        check_match("end", "function", line, lines)
        return node
    end

    -- '{' [field {fieldsep field} [fieldsep]] '}' (lparser.c, constructor).
    local function constructor()
        local line = tok.line
        local node = {tag = "Table", line = line, lines = {line}, fields = {}, seps = {}}
        local lines, fields, seps = node.lines, node.fields, node.seps
        advance()
        repeat
            if is("}") then
                break
            end
            local field
            if tok.type == "name" then
                local ahead = tokens[pos + 1]
                if ahead.type == "error" then
                    error(ahead.value, 0)
                end
                if ahead.value == "=" and ahead.type == "symbol" then
                    field = {tag = "NameField", line = tok.line, lines = {tok.line, ahead.line}, name = tok.value}
                    advance()
                    advance()
                    field.value = expr()
                else
                    -- lparser.c, constructor: luaX_lookahead reads the token
                    -- after the Name and moves the lexer's line past it, so
                    -- when the Name is consumed Lua's `lastline` is that
                    -- token's line. A `(` there is never "ambiguous syntax"
                    -- (`{ f\n(x) }` is a call); funcargs skips the check
                    -- for that one position.
                    looked_ahead = pos + 1
                    field = {tag = "PosField", value = expr()}
                    field.line = field.value.line
                end
            elseif is("[") then
                field = {tag = "KeyField", line = tok.line, lines = {tok.line}}
                advance()
                field.key = expr()
                check_next("]", field.lines)
                check_next("=", field.lines)
                field.value = expr()
            else
                field = {tag = "PosField", value = expr()}
                field.line = field.value.line
            end
            fields[#fields + 1] = field
            local sep = (is(",") or is(";")) and tok.value
            if sep then
                seps[#seps + 1] = sep
                lines[#lines + 1] = tok.line
                advance()
            end
        until not sep
        check_match("}", "{", line, lines)
        return node
    end

    -- funcargs: '(' [explist1] ')' | constructor | STRING. Fills `node`.
    local function funcargs(node)
        local lines = node.lines
        if is("(") then
            local line = tok.line
            local previous = tokens[pos - 1]
            if line ~= (previous.end_line or previous.line) and pos ~= looked_ahead then
                raise("ambiguous syntax (function call x new statement)")
            end
            lines[#lines + 1] = line
            advance()
            node.args = is(")") and {} or explist(lines)
            check_match(")", "(", line, lines)
        elseif is("{") then
            node.args, node.sugar = {constructor()}, true
        elseif tok.type == "string" then
            node.args, node.sugar = {{tag = "String", value = tok.value, raw = tok.raw, line = tok.line}}, true
            advance()
        else
            raise("function arguments expected")
        end
        return node
    end

    -- prefixexp: NAME | '(' expr ')'.
    local function prefixexp()
        if tok.type == "name" then
            return id()
        elseif is("(") then
            local line = tok.line
            local node = {tag = "Paren", line = line, lines = {line}}
            advance()
            node.expr = expr()
            check_match(")", "(", line, node.lines)
            return node
        end
        raise("unexpected symbol")
    end

    -- The suffixes of a primaryexp after its prefixexp `e`:
    -- { '.' NAME | '[' exp ']' | ':' NAME funcargs | funcargs }.
    function suffixedexp(e)
        while true do
            local t = tok
            if t.type == "string" then
                e = funcargs({tag = "Call", line = e.line, lines = {}, func = e})
            elseif t.value == "." then
                local node = {tag = "Member", line = e.line, lines = {t.line}, obj = e}
                advance()
                node.lines[2] = tok.line
                node.name = check_name()
                e = node
            elseif t.value == "[" then
                local node = {tag = "Index", line = e.line, lines = {t.line}, obj = e}
                advance()
                node.key = expr()
                check_next("]", node.lines)
                e = node
            elseif t.value == ":" then
                local node = {tag = "Invoke", line = e.line, lines = {t.line}, obj = e}
                advance()
                node.lines[2] = tok.line
                node.method = check_name()
                e = funcargs(node)
            elseif t.value == "(" or t.value == "{" then
                e = funcargs({tag = "Call", line = e.line, lines = {}, func = e})
            else
                return e
            end
        end
    end

    -- primaryexp: prefixexp { '.' NAME | '[' exp ']' | ':' NAME funcargs | funcargs }.
    function primaryexp()
        return suffixedexp(prefixexp())
    end

    -- Would the token `t` continue a prefixexp: `.`, `[`, `:`, `(`, `{`
    -- or a string argument?
    local function continues_prefixexp(t)
        local ty = t.type
        if ty == "string" then
            return true
        end
        local v = t.value
        return ty == "symbol" and (v == "." or v == "[" or v == ":" or v == "(" or v == "{")
    end

    -- scopeanchor: the spelling `lifetime.scope` at the current token,
    -- tried before prefixexp where `anchor` and `anchoritem` name it
    -- (docs/04-transpiler.md, "Grammar": "the two Names `lifetime` and
    -- `scope` joined by `.`, with nothing after them that would continue
    -- a `prefixexp` ... matches by spelling, whatever `lifetime` names at
    -- that point"). Consumes it and returns a ScopeAnchor, or consumes
    -- nothing and returns nil.
    local function scopeanchor()
        if tok.value ~= "lifetime" or tok.type ~= "name" then
            return nil
        end
        -- The token after a Name exists, since the array ends with <eof>
        -- or an error token, and so does the one after a second Name.
        local dot = tokens[pos + 1]
        if dot.value ~= "." or dot.type ~= "symbol" then
            return nil
        end
        local name = tokens[pos + 2]
        if name.value ~= "scope" or name.type ~= "name" or continues_prefixexp(tokens[pos + 3]) then
            return nil
        end
        local node = {tag = "ScopeAnchor", line = tok.line, lines = {tok.line, dot.line, name.line}}
        advance()
        advance()
        advance()
        return node
    end

    -- A ScopeAnchor read as the ordinary expression it spells, the field
    -- `scope` of `lifetime` (docs/02-semantics.md, "Scopes:
    -- `lifetime.scope`": "Anywhere else `lifetime.scope` is an ordinary
    -- expression"). Used for `x @ (lifetime.scope).f`, where the
    -- parentheses turn out to start a prefixexp.
    local function scope_as_expression(item)
        local lines = item.lines
        return {tag = "Member", line = item.line, lines = {lines[2], lines[3]}, obj = {tag = "Id", name = "lifetime", line = lines[1]}, name = "scope"}
    end

    -- anchoritem: scopeanchor | exp.
    local function anchoritem()
        return scopeanchor() or expr()
    end

    -- The operator `@` or `!@` at the current token applied to `e`:
    -- exp '@' anchor | exp '!@' anchor, where
    -- anchor ::= scopeanchor | prefixexp | '(' anchorlist ')'
    -- (docs/04-transpiler.md, "Grammar"). Returns the Anchor or Hook node.
    local function apply_anchor(e)
        local node = {tag = tok.value == "@" and "Anchor" or "Hook", line = e.line, lines = {tok.line}, expr = e}
        advance()
        local item = scopeanchor()
        if item then
            node.anchors = {item}
            return node
        end
        if not is("(") then
            node.anchors = {primaryexp()}
            return node
        end
        -- A list, or a parenthesised expression that a suffix continues
        -- into a prefixexp (`x @ (t).owner`): the two agree up to `)`.
        local open = tok.line
        advance()
        if is(")") then
            -- docs/02-semantics.md, "Acquiring a lifetime": "An empty list
            -- `@()` is a syntax error."
            raise("empty anchor list")
        end
        local lines = node.lines
        lines[2] = open
        local items = {anchoritem()}
        while is(",") do
            lines[#lines + 1] = tok.line
            advance()
            -- "Lists do not nest": an item is an exp, and a `(` in it opens
            -- Lua's parenthesised expression, which holds no comma.
            items[#items + 1] = anchoritem()
        end
        check_match(")", "(", open, lines)
        if #items == 1 and continues_prefixexp(tok) then
            local inner = items[1]
            if inner.tag == "ScopeAnchor" then
                inner = scope_as_expression(inner)
            end
            local paren = {tag = "Paren", line = open, lines = {open, lines[3]}, expr = inner}
            lines[2], lines[3] = nil, nil
            node.anchors = {suffixedexp(paren)}
            return node
        end
        node.anchors, node.list = items, true
        return node
    end

    -- simpleexp: NUMBER | STRING | nil | true | false | '...' | constructor
    -- | FUNCTION body | primaryexp.
    local function simpleexp()
        local t = tok
        local ty, line = t.type, t.line
        if ty == "number" then
            advance()
            return {tag = "Number", value = t.value, raw = t.raw, line = line}
        elseif ty == "string" then
            advance()
            return {tag = "String", value = t.value, raw = t.raw, line = line}
        elseif ty == "keyword" then
            local v = t.value
            if v == "nil" then
                advance()
                return {tag = "Nil", line = line}
            elseif v == "true" then
                advance()
                return {tag = "True", line = line}
            elseif v == "false" then
                advance()
                return {tag = "False", line = line}
            elseif v == "function" then
                advance()
                return body({tag = "Function", line = line, lines = {line}}, tok.end_line or tok.line)
            end
        elseif ty == "symbol" then
            if t.value == "..." then
                if not fs.is_vararg then
                    raise("cannot use '...' outside a vararg function")
                end
                advance()
                return {tag = "Vararg", line = line}
            elseif t.value == "{" then
                return constructor()
            end
        end
        return primaryexp()
    end

    -- subexpr: (simpleexp | unop subexpr) { binop subexpr }, where only
    -- operators with a left priority above `limit` are taken.
    local function subexpr(limit)
        local e
        local t = tok
        local v = t.type ~= "string" and t.value
        if v == "not" or v == "-" or v == "#" then
            advance()
            e = {tag = "UnOp", line = t.line, lines = {t.line}, op = v, operand = subexpr(UNARY_PRIORITY)}
        else
            e = simpleexp()
        end
        while true do
            t = tok
            local op = t.type ~= "string" and t.value
            local left = LEFT[op]
            if not left or left <= limit then
                return e
            end
            advance()
            e = {tag = "BinOp", line = e.line, lines = {t.line}, op = op, left = e, right = subexpr(RIGHT[op])}
        end
    end

    -- exp: subexpr { '@' anchor | '!@' anchor }. `@` and `!@` are postfix,
    -- of the lowest precedence of any operator, and associate to the left
    -- (docs/04-transpiler.md, "Grammar"; docs/02-semantics.md, "Hooks: the
    -- `!@` operator": "`f !@ a @ b` creates the hook on `a` and then moves
    -- it to `b`"): they apply to the whole expression on their left, and
    -- the expression they end is no operand of a binary operator.
    function expr()
        local e = subexpr(0)
        while anchor_operator() do
            e = apply_anchor(e)
        end
        return e
    end

    -- docs/02-semantics.md, "Named hooks": "A hook created as the value
    -- bound to a name carries that name: `local NAME = f !@ …`, `NAME = f
    -- !@ …` and `t.NAME = f !@ …`". The value of `e @ a` and of `(e)` is
    -- the value of `e`, so the hook is found through them.
    local function name_hook(e, name)
        while true do
            local tag = e.tag
            if tag == "Hook" then
                e.name = name
                return
            elseif tag ~= "Anchor" and tag ~= "Paren" then
                return
            end
            e = e.expr
        end
    end

    -- A loop body: a block inside which `break` is allowed.
    local function loop_block()
        fs.loops = fs.loops + 1
        local b = block()
        fs.loops = fs.loops - 1
        return b
    end

    local function assignable(e)
        local tag = e.tag
        return tag == "Id" or tag == "Member" or tag == "Index"
    end

    local statement_by_keyword = {}

    statement_by_keyword["if"] = function(line)
        local node = {tag = "If", line = line, lines = {line}, conds = {}, blocks = {}}
        local lines = node.lines
        advance()
        node.conds[1] = expr()
        check_next("then", lines)
        node.blocks[1] = block()
        while is("elseif") do
            lines[#lines + 1] = tok.line
            advance()
            node.conds[#node.conds + 1] = expr()
            check_next("then", lines)
            node.blocks[#node.blocks + 1] = block()
        end
        if is("else") then
            lines[#lines + 1] = tok.line
            advance()
            node.else_block = block()
        end
        check_match("end", "if", line, lines)
        return node
    end

    statement_by_keyword["while"] = function(line)
        local node = {tag = "While", line = line, lines = {line}}
        advance()
        node.cond = expr()
        check_next("do", node.lines)
        node.body = loop_block()
        check_match("end", "while", line, node.lines)
        return node
    end

    statement_by_keyword["do"] = function(line)
        local node = {tag = "Do", line = line, lines = {line}}
        advance()
        node.body = block()
        check_match("end", "do", line, node.lines)
        return node
    end

    statement_by_keyword["for"] = function(line)
        local lines = {line}
        advance()
        local first = id()
        local node
        if is("=") then
            node = {tag = "NumericFor", line = line, lines = lines, var = first}
            lines[2] = tok.line
            advance()
            node.start = expr()
            check_next(",", lines)
            node.limit = expr()
            if is(",") then
                lines[#lines + 1] = tok.line
                advance()
                node.step = expr()
            end
        elseif is(",") or is("in") then
            node = {tag = "GenericFor", line = line, lines = lines, vars = {first}}
            while is(",") do
                lines[#lines + 1] = tok.line
                advance()
                node.vars[#node.vars + 1] = id()
            end
            check_next("in", lines)
            node.exprs = explist(lines)
        else
            raise("'=' or 'in' expected")
        end
        check_next("do", lines)
        node.body = loop_block()
        check_match("end", "for", line, lines)
        return node
    end

    statement_by_keyword["repeat"] = function(line)
        local node = {tag = "Repeat", line = line, lines = {line}}
        advance()
        node.body = loop_block()
        check_match("until", "repeat", line, node.lines)
        node.cond = expr()
        return node
    end

    statement_by_keyword["function"] = function(line)
        local ahead = tokens[pos + 1]
        if ahead.value == "(" and ahead.type == "symbol" then
            -- docs/04-transpiler.md, "Grammar": "A statement may start with
            -- `function (`, an anonymous function, which must then be
            -- followed by `!@`" (stat ::= functiondef '!@' anchor).
            advance()
            local func = body({tag = "Function", line = line, lines = {line}}, tok.line)
            if anchor_operator() ~= "!@" then
                raise_expected("!@")
            end
            return {tag = "HookStat", line = line, expr = apply_anchor(func)}
        end
        local func = {tag = "Function", line = line, lines = {line}}
        local node = {tag = "FunctionStat", line = line, func = func}
        advance()
        -- funcname: NAME {'.' NAME} [':' NAME]
        local target = id()
        while is(".") do
            local member = {tag = "Member", line = target.line, lines = {tok.line}, obj = target}
            advance()
            member.lines[2] = tok.line
            member.name = check_name()
            target = member
        end
        node.target = target
        if is(":") then
            node.lines = {tok.line}
            advance()
            node.lines[2] = tok.line
            node.method = check_name()
        end
        body(func, line, node.method ~= nil)
        return node
    end

    statement_by_keyword["local"] = function(line)
        local lines = {line}
        advance()
        if is("function") then
            local func = {tag = "Function", line = tok.line, lines = {tok.line}}
            advance()
            local node = {tag = "LocalFunction", line = line, lines = lines, name = id(), func = func}
            body(func, tok.end_line or tok.line)
            return node
        end
        local node = {tag = "Local", line = line, lines = lines, names = {id()}, exprs = {}}
        while is(",") do
            lines[#lines + 1] = tok.line
            advance()
            node.names[#node.names + 1] = id()
        end
        if is("=") then
            lines[#lines + 1] = tok.line
            advance()
            local exprs, names = explist(lines), node.names
            node.exprs = exprs
            for i = 1, #exprs < #names and #exprs or #names do
                name_hook(exprs[i], names[i].name)
            end
        end
        return node
    end

    -- `return` and `break` end a block (lparser.c, statement: "must be
    -- last statement"); the second result says so.
    statement_by_keyword["return"] = function(line)
        local node = {tag = "Return", line = line, lines = {line}, exprs = {}}
        advance()
        if not (block_follow() or is(";")) then
            node.exprs = explist(node.lines)
        end
        return node, true
    end

    statement_by_keyword["break"] = function(line)
        advance()
        if fs.loops == 0 then
            raise("no loop to break")
        end
        return {tag = "Break", line = line, lines = {line}}, true
    end

    -- exprstat: func | assignment | prefixexp '@' anchor | prefixexp '!@'
    -- anchor (docs/04-transpiler.md, "Grammar"; docs/02-semantics.md,
    -- "Acquiring a lifetime": "The left side must be a `prefixexp`"). One
    -- operator, as the grammar has it: `x @ a @ b` is no statement.
    local function exprstat(line)
        local e = primaryexp()
        local op = anchor_operator()
        if op then
            return {tag = op == "@" and "AnchorStat" or "HookStat", line = line, expr = apply_anchor(e)}
        end
        if e.tag == "Call" or e.tag == "Invoke" then
            return {tag = "CallStat", line = line, call = e}
        end
        local node = {tag = "Set", line = line, lines = {}, targets = {e}}
        local lines, targets = node.lines, node.targets
        while true do
            if not assignable(targets[#targets]) then
                raise("syntax error")
            end
            if not is(",") then
                break
            end
            lines[#lines + 1] = tok.line
            advance()
            targets[#targets + 1] = primaryexp()
        end
        check_next("=", lines)
        local exprs = explist(lines)
        node.exprs = exprs
        for i = 1, #exprs < #targets and #exprs or #targets do
            local target = targets[i]
            -- `NAME =` (an Id) and `t.NAME =` (a Member) name a hook,
            -- `t[k] =` (an Index) does not.
            if target.tag ~= "Index" then
                name_hook(exprs[i], target.name)
            end
        end
        return node
    end

    -- LuaJIT's `goto NAME`, which the transpiler honours in the input
    -- (CLAUDE.md, "Technical decisions"; docs/04-transpiler.md, "Blocks").
    -- As in LuaJIT, `goto` starts one only when a Name follows it, so it
    -- stays an ordinary name wherever a Lua 5.1 chunk can use one.
    local function goto_statement(line)
        advance()
        local name_line = tok.line
        return {tag = "Goto", line = line, lines = {line, name_line}, name = check_name()}
    end

    -- LuaJIT's label, `::NAME::`.
    local function label_statement(line)
        local node = {tag = "Label", line = line, lines = {line}}
        advance()
        node.lines[2] = tok.line
        node.name = check_name()
        check_next("::", node.lines)
        return node
    end

    local function statement()
        local t = tok
        local line, ty = t.line, t.type
        if ty == "keyword" then
            local handler = statement_by_keyword[t.value]
            if handler then
                return handler(line)
            end
        elseif ty == "name" then
            if t.value == "goto" and tokens[pos + 1].type == "name" then
                return goto_statement(line)
            end
        elseif t.value == "::" and ty == "symbol" then
            return label_statement(line)
        end
        return exprstat(line)
    end

    -- block: { stat [';'] }, up to a token that ends a block.
    function block()
        local b = {tag = "Block", line = tok.line}
        local n, last = 0, false
        while not last and not block_follow() do
            local s
            s, last = statement()
            if is(";") then
                s.semi = tok.line
                advance()
            end
            n = n + 1
            b[n] = s
        end
        return b
    end

    local chunk = block()
    if tok.type ~= "eof" then
        raise_expected("<eof>")
    end
    -- The end of the chunk is its own token: LuaJIT records its line as
    -- the main function's last line.
    chunk.lines = {tok.line}
    return chunk
end

return parser
