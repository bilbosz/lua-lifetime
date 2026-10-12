-- lifetime/teal.lua: the Teal front end (task 018), the `teal-lifetime`
-- rock of docs/01-overview.md, "Rocks": "a second rockspec that depends
-- on `lua-lifetime` for the runtime and on `tl`, with a Teal front end
-- and Teal output; the transpiler core and the CLI are shared, and its
-- lexer reads `!@` before Teal's postfix `!`".
--
-- Teal source with the extension (`@`, the list form, `!@`,
-- `lifetime.scope`; docs/02-semantics.md) goes in as a `.tlt` file, plain
-- Teal comes out, and `lifetime run` compiles that Teal with the `tl`
-- module and runs it (docs/04-transpiler.md, "The Teal front end").
--
-- This module is the *dialect* the shared lexer, parser and emitter take
-- (lifetime/lexer.lua, lifetime/parser.lua, lifetime/emit.lua): it knows
-- Teal's grammar, Teal 0.24's `docs/grammar.md` plus the macro call of
-- the development branch, and nothing about ownership. Everything Teal
-- adds to Lua is read into Raw nodes, the tokens as they were with their
-- lines, which the emitter writes back unchanged: a type is never
-- interpreted here, `tl` does that on the output. The exceptions are the
-- expressions inside a type declaration (a record's `where` clause, a
-- macroexp's body), which the parser reads so that the emitter can write
-- them, and which may therefore use the extension like any expression.
--
-- Exports:
--
--   teal.dialect            the dialect: `new(P)` for the parser (below),
--                           the operator tables, and what the emitter
--                           needs for a typed output
--   teal.compile(source, chunkname)
--                           Teal source -> Lua 5.1 source through `tl`
--                           (type-checked, target 5.1), or nil and the
--                           errors, one `FILE:LINE:COL: message` per line
--   teal.install_loader()   `tl.loader()`, once, so that a running program
--                           can require plain `.tl` modules as under `tl run`
--
-- The source extension, `.tlt` (docs/05-decisions.md, "The Teal source
-- extension is `.tlt`"), is the command's business (lifetime/cli.lua,
-- `lang_of`): the core picks the front end without requiring it.

local teal = {}

local sub, format, concat = string.sub, string.format, table.concat

------------------------------------------------------------------------
-- Operators
------------------------------------------------------------------------

-- Teal's binary operator priorities (tl.tl, `precedences`, 2-ary): Lua
-- 5.4's with `is` at the level of the comparisons and `as` above
-- everything; `..` and `^` associate to the right. The right operand of
-- `as` and `is` is a type, read by `type_operator` below.
local LEFT = {
    ["or"] = 1,
    ["and"] = 2,
    ["is"] = 3,
    ["<"] = 3,
    [">"] = 3,
    ["<="] = 3,
    [">="] = 3,
    ["~="] = 3,
    ["=="] = 3,
    ["|"] = 4,
    ["~"] = 5,
    ["&"] = 6,
    ["<<"] = 7,
    [">>"] = 7,
    [".."] = 8,
    ["+"] = 9,
    ["-"] = 9,
    ["*"] = 10,
    ["/"] = 10,
    ["//"] = 10,
    ["%"] = 10,
    ["^"] = 12,
    ["as"] = 50
}
local RIGHT = {}
for op, priority in pairs(LEFT) do
    RIGHT[op] = priority
end
RIGHT[".."] = 7
RIGHT["^"] = 11
-- Teal's unary operators (`not`, `#`, `-`, `~`) bind above `*` and below `^`.
local UNARY_PRIORITY = 11

local TYPE_OPERATORS = {as = true, is = true}

------------------------------------------------------------------------
-- Raw nodes
------------------------------------------------------------------------

-- Spacing hints for the emitter: tokens written with no space before them
-- (`gb`) or after them (`ga`), so that a type comes out as Teal writes
-- it: `{string: number}`, `function(a: T): U`, `Map<K, V>`, `x?: T`.
local GLUE_BEFORE = {
    [")"] = true,
    ["<"] = true,
    ["}"] = true,
    ["]"] = true,
    [","] = true,
    [">"] = true,
    [":"] = true,
    ["?"] = true,
    ["."] = true,
    ["..."] = true,
    ["!"] = true
}
local GLUE_AFTER = {
    ["("] = true,
    ["{"] = true,
    ["["] = true,
    ["<"] = true,
    ["."] = true
}

local function new_raw()
    return {tag = "Raw", n = 0}
end

-- Append a token's text on its line. `gb`/`ga` override the tables.
local function push_token(raw, text, line, gb, ga)
    local n = raw.n + 1
    raw.n = n
    if gb == nil then
        gb = GLUE_BEFORE[text] or false
    end
    if ga == nil then
        ga = GLUE_AFTER[text] or false
    end
    raw[n] = {text = text, line = line, gb = gb, ga = ga}
end

local function push_node(raw, node)
    local n = raw.n + 1
    raw.n = n
    raw[n] = node
end

------------------------------------------------------------------------
-- The dialect
------------------------------------------------------------------------

local dialect = {left = LEFT, right = RIGHT, unary_priority = UNARY_PRIORITY, type_operators = TYPE_OPERATORS}
teal.dialect = dialect

-- The hooks for one parse. `P` is the parser's primitive set
-- (lifetime/parser.lua, `parser.parse`): `current()`, `peek(k)`,
-- `advance()`, `is(s)`, `raise(message)`, `raise_expected(what)`,
-- `check_match(what, who, where, lines)`, `id()`, `expr()`, `body(node,
-- line)` and `declaration(tag, line, lines)`. Every hook leaves the
-- parser on the first token it did not read.
function dialect.new(P)
    local current, peek, advance, is, raise, raise_expected = P.current, P.peek, P.advance, P.is, P.raise, P.raise_expected

    -- Is the current token the Name `word`? Teal's `global`, `record`,
    -- `enum`, `interface`, `type`, `macroexp`, `is`, `where`, `userdata`
    -- and `metamethod` are contextual: names everywhere else.
    local function is_word(word)
        local t = current()
        return t.value == word and t.type == "name"
    end

    -- Append the current token to `raw` and move on. Numbers and strings
    -- keep their spelling.
    local function take(raw, gb, ga)
        local t = current()
        local ty = t.type
        push_token(raw, (ty == "string" or ty == "number") and t.raw or t.value, t.line, gb, ga)
        advance()
    end

    local function expect(raw, s)
        if not is(s) then
            raise_expected(s)
        end
        take(raw)
    end

    -- The `end` (or other closer) of a construct opened by `who` at line
    -- `where`, with Lua's "(to close ... at line N)" when it is missing.
    local function expect_match(raw, what, who, where)
        if not is(what) then
            P.check_match(what, who, where, {})
        end
        take(raw)
    end

    local function name(raw)
        if current().type ~= "name" then
            raise_expected("<name>")
        end
        take(raw)
    end

    local function string_literal(raw)
        if current().type ~= "string" then
            raise("expected a string literal")
        end
        take(raw)
    end

    local parse_type

    -- '<' item {',' item} '>' (tl.tl, parse_anglebracket_list). The lexer
    -- reads `>>` as one token, so `Box<Box<integer>>` ends in `>>`: as tl
    -- does, the inner list takes one `>` of it and leaves the other for
    -- the list around it, by rewriting the token in place.
    local function anglebracket_list(raw, item)
        expect(raw, "<")
        item(raw)
        while is(",") do
            take(raw)
            item(raw)
        end
        local t = current()
        if t.value == ">>" and t.type == "symbol" then
            push_token(raw, ">", t.line)
            t.value = ">"
            return
        end
        expect(raw, ">")
    end

    -- typearg ::= Name ['is' type] (tl.tl, parse_typearg: a constraint).
    local function typearg(raw)
        name(raw)
        if is_word("is") then
            take(raw)
            parse_type(raw)
        end
    end

    local function typeargs_if_any(raw)
        if is("<") then
            anglebracket_list(raw, typearg)
        end
    end

    -- After a comma in a return list written without parentheses, does a
    -- parameter follow (`Name ':'`) rather than another return type? The
    -- lookahead of tl.tl's parse_trying_list for `cb: function(): T, n:
    -- integer`.
    local function parameter_follows()
        local ahead = peek(1)
        local colon = peek(2)
        return ahead.type == "name" and colon.value == ":" and colon.type == "symbol"
    end

    -- retlist ::= ':' ('(' [typelist] ['...'] ')' | typelist ['...'])
    -- (tl.tl, parse_type_list in mode "rets"). Returns false when there is
    -- no `:`.
    local function rets(raw)
        if not is(":") then
            return false
        end
        take(raw)
        local paren = is("(")
        if paren then
            take(raw)
        end
        if not (paren and is(")")) then
            parse_type(raw)
            while is(",") and (paren or not parameter_follows()) do
                take(raw)
                parse_type(raw)
            end
            if is("...") then
                take(raw)
            end
        end
        if paren then
            expect(raw, ")")
        end
        return true
    end

    -- partype ::= Name ['?'] ':' type | ['?'] type | '...' ':' type, each
    -- optionally followed by '...' (tl.tl, parse_argument_type).
    local function argument_type(raw)
        local t = current()
        local ahead = peek(1)
        if t.type == "name" and ahead.type == "symbol" and (ahead.value == "?" or ahead.value == ":") then
            take(raw)
            if is("?") then
                take(raw)
            end
            if is(":") then
                take(raw)
            end
            parse_type(raw)
        elseif is("?") then
            take(raw)
            parse_type(raw)
        elseif is("...") then
            take(raw)
            if is(":") then
                take(raw)
                parse_type(raw)
            end
        else
            parse_type(raw)
        end
        if is("...") then
            take(raw)
        end
    end

    -- '(' [partype {',' partype}] ')', glued to the `function` or the
    -- type arguments before it.
    local function argument_type_list(raw)
        if not is("(") then
            raise_expected("(")
        end
        take(raw, true)
        if not is(")") then
            argument_type(raw)
            while is(",") do
                take(raw)
                argument_type(raw)
            end
        end
        expect(raw, ")")
    end

    -- basetype ::= nominal | '{' type {',' type} '}' | '{' type ':' type '}'
    -- | functiontype | 'nil' (tl.tl, parse_base_type and
    -- parse_simple_type_or_nominal).
    local function base_type(raw)
        local t = current()
        if t.type == "name" then
            take(raw)
            while is(".") do
                take(raw)
                name(raw)
            end
            if is("<") then
                anglebracket_list(raw, parse_type)
            end
        elseif t.type == "keyword" and t.value == "nil" then
            take(raw)
        elseif t.type == "keyword" and t.value == "function" then
            take(raw)
            typeargs_if_any(raw)
            if is("(") then
                argument_type_list(raw)
                rets(raw)
            end
        elseif is("{") then
            take(raw)
            parse_type(raw)
            if is(",") then
                repeat
                    take(raw)
                    parse_type(raw)
                until not is(",")
            elseif is(":") then
                take(raw)
                parse_type(raw)
            end
            expect(raw, "}")
        else
            raise("expected a type")
        end
    end

    -- type ::= '(' type ')' | basetype {'|' basetype} (tl.tl, parse_type).
    function parse_type(raw)
        if is("(") then
            take(raw)
            parse_type(raw)
            expect(raw, ")")
            return
        end
        base_type(raw)
        while is("|") do
            take(raw)
            base_type(raw)
        end
    end

    local type_body, newtype

    -- enumbody ::= {LiteralString} 'end'.
    local function enum_body(raw, line)
        while not is("end") do
            if current().type == "eof" then
                P.check_match("end", "enum", line, {})
            end
            string_literal(raw)
        end
        take(raw)
    end

    -- macroexpbody ::= [typeargs] '(' [parlist] ')' [retlist] retstat
    -- 'end'; the returned expressions are parsed, so the emitter can
    -- write them.
    local function macroexp_body(raw, line)
        typeargs_if_any(raw)
        expect(raw, "(")
        if not is(")") then
            repeat
                if is("...") then
                    take(raw)
                else
                    name(raw)
                    if is("?") then
                        take(raw)
                    end
                end
                if is(":") then
                    take(raw)
                    parse_type(raw)
                end
                local more = is(",")
                if more then
                    take(raw)
                end
            until not more
        end
        expect(raw, ")")
        rets(raw)
        expect(raw, "return")
        if not (is("end") or is(";")) then
            push_node(raw, P.expr())
            while is(",") do
                take(raw)
                push_node(raw, P.expr())
            end
        end
        if is(";") then
            take(raw)
        end
        expect_match(raw, "end", "macroexp", line)
    end

    -- recordbody ::= [typeargs] ['is' interfacelist] ['where' exp]
    -- {recordentry} 'end' (tl.tl, parse_record_body); `kind` is "record"
    -- or "interface", `line` the line of that word. The `where` clause is
    -- an expression and is parsed as one.
    local function record_body(raw, kind, line)
        typeargs_if_any(raw)
        if is("{") then
            take(raw)
            parse_type(raw)
            expect(raw, "}")
        end
        if is_word("is") then
            take(raw)
            if is("{") then
                take(raw)
                parse_type(raw)
                expect(raw, "}")
                if is(",") then
                    take(raw)
                    parse_type(raw)
                    while is(",") do
                        take(raw)
                        parse_type(raw)
                    end
                end
            else
                parse_type(raw)
                while is(",") do
                    take(raw)
                    parse_type(raw)
                end
            end
        end
        if is_word("where") then
            take(raw)
            push_node(raw, P.expr())
        end
        while not is("end") do
            local t = current()
            if t.type == "eof" then
                P.check_match("end", kind, line, {})
            end
            local word = t.type == "name" and t.value
            local ahead = peek(1)
            -- `userdata: T`, `type: T`, `record: T` are fields of those names.
            local field = ahead.value == ":" and ahead.type == "symbol"
            if word == "userdata" and not field then
                take(raw)
            elseif word == "type" and not field then
                take(raw)
                name(raw)
                expect(raw, "=")
                newtype(raw)
            elseif (word == "record" or word == "interface" or word == "enum") and not field then
                take(raw)
                name(raw)
                type_body(raw, word, t.line)
            else
                if word == "metamethod" and not field then
                    take(raw)
                end
                if is("[") then
                    take(raw)
                    string_literal(raw)
                    expect(raw, "]")
                else
                    name(raw)
                end
                expect(raw, ":")
                parse_type(raw)
                if is("=") then
                    -- recordkey ':' functiontype '=' 'macroexp' macroexpbody
                    local eq = current()
                    take(raw)
                    if not is_word("macroexp") then
                        raise("expected 'macroexp'")
                    end
                    take(raw)
                    macroexp_body(raw, eq.line)
                end
            end
        end
        take(raw)
    end

    -- The body of a `record`, `interface` or `enum` named `kind`, whose
    -- word is on `line`.
    function type_body(raw, kind, line)
        if kind == "enum" then
            enum_body(raw, line)
        else
            record_body(raw, kind, line)
        end
    end

    -- newtype ::= 'record' recordbody | 'interface' recordbody | 'enum'
    -- enumbody | 'require' '(' LiteralString ')' {'.' Name} | type.
    function newtype(raw)
        local t = current()
        if t.type == "name" then
            local word = t.value
            if word == "record" or word == "interface" or word == "enum" then
                take(raw)
                type_body(raw, word, t.line)
                return
            elseif word == "require" and peek(1).value == "(" and peek(1).type == "symbol" then
                take(raw)
                take(raw)
                string_literal(raw)
                expect(raw, ")")
                while is(".") do
                    take(raw)
                    name(raw)
                end
                return
            end
        end
        parse_type(raw)
    end

    -- A type declaration after `local` or `global` (`keyword`, on `line`,
    -- already consumed): `record NAME recordbody`, `interface NAME
    -- recordbody`, `enum NAME enumbody`, `type NAME ['=' newtype]`,
    -- `macroexp NAME macroexpbody`. The current token is the kind word, a
    -- Name follows it. Returns the Teal statement node.
    local function type_declaration(keyword, line)
        local raw = new_raw()
        push_token(raw, keyword, line)
        local t = current()
        local word = t.value
        take(raw)
        local declared = current().value
        name(raw)
        if word == "type" then
            if is("=") or keyword == "local" then
                expect(raw, "=")
                newtype(raw)
            end
        elseif word == "macroexp" then
            macroexp_body(raw, t.line)
        else
            type_body(raw, word, t.line)
        end
        -- `name` is the declared local, for the emitter's shadowing count
        -- (`local record lifetime` shadows the runtime's name).
        return {tag = "Teal", line = line, raw = raw, name = keyword == "local" and declared or nil}
    end

    local DECLARATION_WORDS = {record = true, interface = true, enum = true, type = true, macroexp = true}

    local D = {}

    -- '<' Name {',' Name} '>' after a function's name: `function f<T>(…)`.
    function D.typeargs(node)
        if is("<") then
            local raw = new_raw()
            anglebracket_list(raw, typearg)
            node.typeargs = raw
        end
    end

    -- parname ::= Name ['?'] [':' type].
    function D.param(param)
        if is("?") then
            param.opt = current().line
            advance()
        end
        if is(":") then
            local raw = new_raw()
            take(raw)
            parse_type(raw)
            param.type = raw
        end
    end

    -- '...' [':' type].
    function D.vararg(node)
        if is(":") then
            local raw = new_raw()
            take(raw)
            parse_type(raw)
            node.vararg_type = raw
        end
    end

    -- [':' retlist] after a function's ')'.
    function D.rets(node)
        if is(":") then
            local raw = new_raw()
            rets(raw)
            node.rets = raw
        end
    end

    -- attrib ::= '<' Name '>' after a local's or global's name. Written
    -- with a space before it, as Teal does: `local x <const> = 1`.
    function D.attrib(id)
        if is("<") then
            local raw = new_raw()
            take(raw, false, true)
            name(raw)
            expect(raw, ">")
            id.attrib = raw
        end
    end

    -- [':' typelist] after the names of a local or global declaration.
    function D.typelist(node)
        if is(":") then
            local raw = new_raw()
            take(raw)
            parse_type(raw)
            while is(",") do
                take(raw)
                parse_type(raw)
            end
            node.types = raw
        end
    end

    -- ':' type, the type of a table field (`{name: T = v}`).
    function D.annotation()
        local raw = new_raw()
        expect(raw, ":")
        parse_type(raw)
        return raw
    end

    -- After `local` (on `line`): a type declaration when the current
    -- token is one of the declaration words and a Name follows (tl.tl,
    -- parse_local: `local type = 1` is an ordinary local), else nil.
    function D.local_declaration(line)
        local t = current()
        if t.type == "name" and DECLARATION_WORDS[t.value] and peek(1).type == "name" then
            return type_declaration("local", line)
        end
        return nil
    end

    -- At the Name `global` (on `line`): `global function Name funcbody`, a
    -- type declaration, or `global attnamelist [':' typelist] ['='
    -- explist]` (tl.tl, parse_global); nil when `global` is an ordinary
    -- name here (`global = 1`, `global.x`), "global is a soft keyword".
    function D.global_statement(line)
        local ahead = peek(1)
        if ahead.type == "keyword" and ahead.value == "function" then
            advance()
            local fline = current().line
            advance()
            local func = {tag = "Function", line = fline, lines = {fline}}
            local node = {tag = "GlobalFunction", line = line, lines = {line}, name = P.id(), func = func}
            local t = current()
            P.body(func, t.end_line or t.line)
            return node
        elseif ahead.type == "name" then
            advance()
            if DECLARATION_WORDS[ahead.value] and ahead.value ~= "macroexp" and peek(1).type == "name" then
                return type_declaration("global", line)
            end
            return P.declaration("Global", line, {line})
        end
        return nil
    end

    -- exp 'as' type | exp 'as' '(' typelist ')' | exp 'is' type, the
    -- operator already consumed (its line is `line`). An As node counts
    -- the types of its tuple in `arity`: `f() as (A, B)` is two values
    -- (lifetime/emit.lua, the fixed-count `return`).
    function D.type_operator(e, op, line)
        local node = {tag = op == "as" and "As" or "Is", line = e.line, lines = {line}, expr = e}
        local raw = new_raw()
        local arity = 1
        if op == "as" and is("(") then
            take(raw)
            parse_type(raw)
            while is(",") do
                take(raw)
                parse_type(raw)
                arity = arity + 1
            end
            expect(raw, ")")
        else
            parse_type(raw)
        end
        node.type = raw
        if op == "as" then
            node.arity = arity
        end
        return node
    end

    return D
end

------------------------------------------------------------------------
-- What the emitter needs for Teal output (lifetime/emit.lua)
------------------------------------------------------------------------

-- The header's packing helpers, typed (docs/04-transpiler.md, "The Teal
-- front end"): `table.unpack` behind a declared type, since Teal cannot
-- infer a type variable from `{any}`, and a pack that returns the table
-- and the count as two values, since a record with an array part is not
-- a `{T}` to `table.unpack`. `tl` with target 5.1 turns `table.unpack`
-- into `unpack or table.unpack` in its own preamble.
dialect.pack_header = "local __lt_select = select; local __lt_unpack: function({any}, integer, integer): any... = table.unpack; local function __lt_pack(...: any): {any}, integer return {...}, __lt_select(\"#\", ...) end;"

-- A `return` that packs a call's values declares two locals and casts the
-- unpacked values to the function's return types (`as (T1, …, Tn)`),
-- because `any` is assignable to no declared return type in Teal.
dialect.typed_returns = true

-- The cast for the values a packed `return` hands back, from the `rets`
-- Raw of the enclosing function (`: T1, …, Tn` or `: (T1, …, Tn)`), or nil
-- when the function declares none or ends them with `...`, which no cast
-- can spell; `tl` then reports the mismatch, as it does for any `any...`
-- return, and the program casts or declares by hand.
function dialect.return_cast(rets)
    if not rets then
        return nil
    end
    local parts, np, glue = {}, 0, true
    for i = 2, rets.n do
        local item = rets[i]
        local text = item.text
        if text == "..." then
            return nil
        end
        if not (glue or item.gb) then
            np = np + 1
            parts[np] = " "
        end
        np = np + 1
        parts[np] = text
        glue = item.ga
    end
    local text = concat(parts, "", 1, np)
    if sub(text, 1, 1) ~= "(" then
        text = "(" .. text .. ")"
    end
    return " as " .. text
end

------------------------------------------------------------------------
-- Teal -> Lua, through the `tl` module
------------------------------------------------------------------------

-- The generated Lua keeps every statement on its line, so that positions
-- in error messages and tracebacks name the `.tlt` file and its line.
local GENERATE_OPTIONS = {preserve_indent = true, preserve_newlines = true, preserve_hashbang = false}

-- The generated code and the runtime target Lua 5.1 and LuaJIT
-- (docs/02-semantics.md, "Host"); `tl` renders `//` and the bitwise
-- operators for 5.1 and prepends its compat preamble where it needs one.
local GEN_TARGET = "5.1"

local function require_tl(chunkname, what)
    local ok, tl = pcall(require, "tl")
    if not ok then
        return nil, format("cannot %s %s: the Teal compiler is not installed (module tl, the tl rock)", what, chunkname)
    end
    return tl
end

-- Compile Teal `source` named `chunkname` to Lua 5.1 source. Returns the
-- Lua, or nil and the errors `tl` found, one `FILE:LINE:COL: message` per
-- line in `tl`'s own shape, syntax errors first. Any error but `tl`'s
-- own findings (a missing `tl`, a generator failure) is one line too.
function teal.compile(source, chunkname)
    local tl, err = require_tl(chunkname, "compile")
    if not tl then
        return nil, err
    end
    local env, env_error = tl.new_env({defaults = {gen_target = GEN_TARGET}})
    if not env then
        return nil, format("cannot compile %s: %s", chunkname, tostring(env_error))
    end
    local result = tl.check_string(source, env, chunkname, "tl")
    local messages, n = {}, 0
    for _, list in ipairs({result.syntax_errors, result.type_errors}) do
        for _, e in ipairs(list or {}) do
            n = n + 1
            messages[n] = format("%s:%d:%d: %s", e.filename or chunkname, e.y or 0, e.x or 0, e.msg)
        end
    end
    if n > 0 then
        return nil, concat(messages, "\n", 1, n)
    end
    local code, gen_error = tl.generate(result.ast, GEN_TARGET, GENERATE_OPTIONS)
    if not code then
        return nil, format("cannot compile %s: %s", chunkname, tostring(gen_error))
    end
    return code
end

local loader_installed = false

-- Install `tl`'s package loader, once, so that the program `lifetime run`
-- starts can require plain `.tl` modules, as a program under `tl run`
-- can. Returns true, or nil and a message when `tl` is missing.
function teal.install_loader(chunkname)
    if loader_installed then
        return true
    end
    local tl, err = require_tl(chunkname, "run")
    if not tl then
        return nil, err
    end
    tl.loader()
    loader_installed = true
    return true
end

return teal
