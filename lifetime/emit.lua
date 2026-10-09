-- lifetime/emit.lua: code generation.
--
-- Turns the AST into Lua 5.1 source per docs/04-transpiler.md: the chunk
-- header, what `@` expands to, hooks (`!@`), block prologues and
-- epilogues on every exit path (the error path is the runtime's),
-- nothing per function. Exports `emit(ast)`.
--
-- Task 001 implements the plain Lua round trip: every token of the AST is
-- written back on the line it came from (docs/04-transpiler.md,
-- "Pipeline": "The emitter keeps every statement on its source line"; "A
-- plain Lua chunk with no extension syntax transpiles to itself modulo
-- whitespace"). Statements and leaves carry `line`, the other tokens come
-- from the node's `lines` (lifetime/parser.lua); a token whose line is
-- ahead of the output starts a new line, any other token follows on the
-- current one, separated by a space where readability or the lexer wants
-- one. Comments are not kept. Since the token sequence and the line of
-- every token are those of the source, Lua compiles the output to the same
-- code with the same line information as the input. Task 006 adds the
-- extension.

local count_newlines = require("lifetime.lexer").count_newlines

local emit = {}

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

local byte, rep, format, gsub = string.byte, string.rep, string.format, string.gsub
local concat = table.concat

local INDENT = "    "

-- Is the byte a letter, a digit or `_`?
local function is_word(b)
    return b and ((b >= 97 and b <= 122) or (b >= 65 and b <= 90) or (b >= 48 and b <= 57) or b == 95)
end

-- Would `prev` immediately followed by `text` lex differently from the two
-- tokens apart? `prev_number` says `prev` is a numeral, which swallows a
-- following `.` or letter.
local function must_separate(prev, text, prev_number)
    local a, b = byte(prev, -1), byte(text, 1)
    if is_word(a) and is_word(b) then
        return true
    end
    if b == 46 then -- `.`
        return a == 46 or prev_number
    end
    if b == 61 then -- `=` after `=`, `<`, `>`, `~`, `[`
        return a == 61 or a == 60 or a == 62 or a == 126 or a == 91
    end
    return (a == 45 and b == 45) or (a == 91 and b == 91) -- `--` starts a comment, `[[` a long string
end

-- The output state: pieces, the current line, the block depth and whether
-- a statement is under way (its continuation lines are indented one level
-- deeper), the last token and whether the next one is glued to it.
local function new_state()
    return {buf = {}, n = 0, line = 1, depth = 0, continued = false, last = nil, last_number = false, glue = false}
end

-- Move the output to `line` if it is ahead.
local function advance(st, line)
    if line and line > st.line then
        st.n = st.n + 1
        st.buf[st.n] = rep("\n", line - st.line) .. rep(INDENT, st.continued and st.depth + 1 or st.depth)
        st.line = line
        st.last = nil
    end
end

-- Write one token on `line` (nil: the current line). `glue_before` asks
-- for no space before it, `glue_after` for none after it; the lexer's
-- needs override both.
local function put(st, text, line, glue_before, glue_after, is_number)
    advance(st, line)
    local last = st.last
    if last and (not (glue_before or st.glue) or must_separate(last, text, st.last_number)) then
        st.n = st.n + 1
        st.buf[st.n] = " "
    end
    st.n = st.n + 1
    st.buf[st.n] = text
    st.last, st.last_number, st.glue = text, is_number or false, glue_after or false
end

-- A string literal for a value with no source spelling (a node built by a
-- later stage): `%q`, with the line breaks escaped so that it stays on
-- one line.
local function quote(value)
    return (gsub(format("%q", value), "\\\n", "\\n"))
end

local function number_text(value)
    if value == math.floor(value) and value >= -2 ^ 53 and value <= 2 ^ 53 then
        return format("%d", value)
    end
    return format("%.17g", value)
end

local emit_expr, emit_block

-- An expression list whose commas are the node's own tokens from index
-- `k + 1` on. Returns the index of the last comma.
local function emit_explist(st, list, node, k)
    local lines = node.lines
    for i = 1, #list do
        if i > 1 then
            k = k + 1
            put(st, ",", lines and lines[k], true)
        end
        emit_expr(st, list[i])
    end
    return k
end

-- The arguments of a Call or an Invoke whose own tokens before `(` are
-- `k` in number.
local function emit_args(st, node, k)
    if node.sugar then
        emit_expr(st, node.args[1])
        return
    end
    local lines = node.lines
    put(st, "(", lines and lines[k + 1], true, true)
    k = emit_explist(st, node.args, node, k + 1)
    put(st, ")", lines and lines[k + 1], true)
end

-- A function from the keyword `function` to `end`. `name` (an expression)
-- and `method` (a string, the tokens being `stat`'s) come between
-- `function` and `(` in a statement.
local function emit_function(st, f, name, method, stat)
    local lines = f.lines
    put(st, "function", lines and lines[1])
    if name then
        emit_expr(st, name)
        if method then
            local slines = stat.lines
            put(st, ":", slines and slines[1], true, true)
            put(st, method, slines and slines[2])
        end
    end
    put(st, "(", lines and lines[2], true, true)
    local k = 2
    local params = f.params
    for i = 1, #params do
        if i > 1 then
            k = k + 1
            put(st, ",", lines and lines[k], true)
        end
        emit_expr(st, params[i])
    end
    if f.is_vararg then
        if #params > 0 then
            k = k + 1
            put(st, ",", lines and lines[k], true)
        end
        k = k + 1
        put(st, "...", lines and lines[k])
    end
    put(st, ")", lines and lines[k + 1], true)
    emit_block(st, f.body)
    put(st, "end", lines and lines[k + 2])
end

local function emit_table(st, t)
    local lines, fields, seps = t.lines, t.fields, t.seps
    put(st, "{", lines and lines[1], false, true)
    for i = 1, #fields do
        local field = fields[i]
        local tag, flines = field.tag, field.lines
        if tag == "NameField" then
            put(st, field.name, flines and flines[1])
            put(st, "=", flines and flines[2])
        elseif tag == "KeyField" then
            put(st, "[", flines and flines[1], false, true)
            emit_expr(st, field.key)
            put(st, "]", flines and flines[2], true)
            put(st, "=", flines and flines[3])
        end
        emit_expr(st, field.value)
        local sep = seps[i] or (i < #fields and ",")
        if sep then
            put(st, sep, lines and lines[i + 1], true)
        end
    end
    put(st, "}", lines and lines[#seps + 2], true)
end

local EXPR = {}

EXPR.Id = function(st, e)
    put(st, e.name, e.line)
end

EXPR.Nil = function(st, e)
    put(st, "nil", e.line)
end

EXPR.True = function(st, e)
    put(st, "true", e.line)
end

EXPR.False = function(st, e)
    put(st, "false", e.line)
end

EXPR.Vararg = function(st, e)
    put(st, "...", e.line)
end

EXPR.Number = function(st, e)
    put(st, e.raw or number_text(e.value), e.line, false, false, true)
end

-- A string keeps its spelling; one that spans lines moves the output on
-- by as many lines.
EXPR.String = function(st, e)
    local text = e.raw or quote(e.value)
    put(st, text, e.line)
    st.line = st.line + count_newlines(text)
end

EXPR.Function = function(st, e)
    emit_function(st, e)
end

EXPR.Table = emit_table

EXPR.Paren = function(st, e)
    local lines = e.lines
    put(st, "(", lines and lines[1], false, true)
    emit_expr(st, e.expr)
    put(st, ")", lines and lines[2], true)
end

EXPR.Member = function(st, e)
    local lines = e.lines
    emit_expr(st, e.obj)
    put(st, ".", lines and lines[1], true, true)
    put(st, e.name, lines and lines[2])
end

EXPR.Index = function(st, e)
    local lines = e.lines
    emit_expr(st, e.obj)
    put(st, "[", lines and lines[1], true, true)
    emit_expr(st, e.key)
    put(st, "]", lines and lines[2], true)
end

EXPR.Call = function(st, e)
    emit_expr(st, e.func)
    emit_args(st, e, 0)
end

EXPR.Invoke = function(st, e)
    local lines = e.lines
    emit_expr(st, e.obj)
    put(st, ":", lines and lines[1], true, true)
    put(st, e.method, lines and lines[2])
    emit_args(st, e, 2)
end

EXPR.BinOp = function(st, e)
    emit_expr(st, e.left)
    put(st, e.op, e.lines and e.lines[1])
    emit_expr(st, e.right)
end

EXPR.UnOp = function(st, e)
    local op = e.op
    put(st, op, e.lines and e.lines[1], false, op ~= "not")
    emit_expr(st, e.operand)
end

function emit_expr(st, e)
    local f = EXPR[e.tag]
    if not f then
        error("emit: unknown expression node '" .. tostring(e.tag) .. "'", 2)
    end
    f(st, e)
end

local STAT = {}

STAT.Local = function(st, s)
    local lines = s.lines
    put(st, "local", lines and lines[1])
    local k = 1
    local names = s.names
    for i = 1, #names do
        if i > 1 then
            k = k + 1
            put(st, ",", lines and lines[k], true)
        end
        emit_expr(st, names[i])
    end
    if #s.exprs > 0 then
        k = k + 1
        put(st, "=", lines and lines[k])
        emit_explist(st, s.exprs, s, k)
    end
end

STAT.LocalFunction = function(st, s)
    put(st, "local", s.lines and s.lines[1])
    emit_function(st, s.func, s.name)
end

STAT.FunctionStat = function(st, s)
    emit_function(st, s.func, s.target, s.method, s)
end

STAT.Set = function(st, s)
    local k = emit_explist(st, s.targets, s, 0) + 1
    put(st, "=", s.lines and s.lines[k])
    emit_explist(st, s.exprs, s, k)
end

STAT.CallStat = function(st, s)
    emit_expr(st, s.call)
end

STAT.Do = function(st, s)
    local lines = s.lines
    put(st, "do", lines and lines[1])
    emit_block(st, s.body)
    put(st, "end", lines and lines[2])
end

STAT.While = function(st, s)
    local lines = s.lines
    put(st, "while", lines and lines[1])
    emit_expr(st, s.cond)
    put(st, "do", lines and lines[2])
    emit_block(st, s.body)
    put(st, "end", lines and lines[3])
end

STAT.Repeat = function(st, s)
    local lines = s.lines
    put(st, "repeat", lines and lines[1])
    emit_block(st, s.body)
    put(st, "until", lines and lines[2])
    emit_expr(st, s.cond)
end

STAT.If = function(st, s)
    local lines = s.lines
    local conds, blocks = s.conds, s.blocks
    local k = 1
    put(st, "if", lines and lines[1])
    for i = 1, #conds do
        if i > 1 then
            k = k + 1
            put(st, "elseif", lines and lines[k])
        end
        emit_expr(st, conds[i])
        k = k + 1
        put(st, "then", lines and lines[k])
        emit_block(st, blocks[i])
    end
    if s.else_block then
        k = k + 1
        put(st, "else", lines and lines[k])
        emit_block(st, s.else_block)
    end
    put(st, "end", lines and lines[k + 1])
end

STAT.NumericFor = function(st, s)
    local lines = s.lines
    put(st, "for", lines and lines[1])
    emit_expr(st, s.var)
    put(st, "=", lines and lines[2])
    emit_expr(st, s.start)
    put(st, ",", lines and lines[3], true)
    emit_expr(st, s.limit)
    local k = 3
    if s.step then
        k = 4
        put(st, ",", lines and lines[4], true)
        emit_expr(st, s.step)
    end
    put(st, "do", lines and lines[k + 1])
    emit_block(st, s.body)
    put(st, "end", lines and lines[k + 2])
end

STAT.GenericFor = function(st, s)
    local lines = s.lines
    put(st, "for", lines and lines[1])
    local k = emit_explist(st, s.vars, s, 1) + 1
    put(st, "in", lines and lines[k])
    k = emit_explist(st, s.exprs, s, k)
    put(st, "do", lines and lines[k + 1])
    emit_block(st, s.body)
    put(st, "end", lines and lines[k + 2])
end

STAT.Return = function(st, s)
    put(st, "return", s.lines and s.lines[1])
    emit_explist(st, s.exprs, s, 1)
end

STAT.Break = function(st, s)
    put(st, "break", s.lines and s.lines[1])
end

local function emit_statement(st, s)
    local f = STAT[s.tag]
    if not f then
        error("emit: unknown statement node '" .. tostring(s.tag) .. "'", 2)
    end
    -- docs/04-transpiler.md, "Pipeline": every statement on its source line.
    st.continued = false
    advance(st, s.line)
    st.continued = true
    f(st, s)
    if s.semi then
        put(st, ";", s.semi, true)
    end
end

-- The statements of a block, one indentation level deeper.
function emit_block(st, b)
    st.depth = st.depth + 1
    for i = 1, #b do
        emit_statement(st, b[i])
    end
    st.depth = st.depth - 1
    st.continued = false
end

-- Emit a chunk (the Block that parser.parse returns) as Lua source.
function emit.emit(ast)
    local st = new_state()
    for i = 1, #ast do
        emit_statement(st, ast[i])
    end
    if ast.lines then
        -- Up to the line of <eof>, so that the output has the source's
        -- number of lines (LuaJIT records it in the main function).
        st.continued = false
        advance(st, ast.lines[1])
    elseif st.n > 0 then
        st.n = st.n + 1
        st.buf[st.n] = "\n"
    end
    return concat(st.buf, "", 1, st.n)
end

return emit
