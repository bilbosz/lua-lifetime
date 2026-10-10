-- lifetime/emit.lua: code generation.
--
-- Turns the AST into Lua 5.1 source per docs/04-transpiler.md: the chunk
-- header, what `@` expands to, hooks (`!@`), block prologues and
-- epilogues on every ordinary exit path (the error path is the
-- runtime's), nothing per function. Exports `emit(ast, chunkname)`.
--
-- Every token of the AST is written back on the line it came from
-- (docs/04-transpiler.md, "Pipeline": "The emitter keeps every statement
-- on its source line"; "A plain Lua chunk with no extension syntax
-- transpiles to itself modulo whitespace"). Statements and leaves carry
-- `line`, the other tokens come from the node's `lines`
-- (lifetime/parser.lua); a token whose line is ahead of the output starts
-- a new line, any other token follows on the current one, separated by a
-- space where readability or the lexer wants one. Comments are not kept.
-- Generated code has no line of its own: it follows on the line of the
-- token it belongs to ("where generated code needs extra lines it is
-- written on the same line, separated by `;`"), and every generated
-- statement ends with `;`, so that a following statement starting with
-- `(` stays a statement. A chunk with no extension syntax that does not
-- name `lifetime` is therefore its input, token for token and line for
-- line, and Lua compiles it to the same bytecode. LuaJIT's `goto` and
-- labels are written as they came.
--
-- What the extension becomes (docs/04-transpiler.md):
--
-- * The header, at the start of line 1, binds the runtime and the
--   runtime functions the chunk calls to locals ("The generated chunk
--   header"): `lifetime`, then `__lt_attach`, `__lt_hook`, `__lt_enter`
--   and `__lt_exit` when it uses them, and `__lt_pack` with `__lt_unpack`
--   when a `return` passes a call's or `...`'s values through an
--   epilogue.
-- * `e @ a` is `__lt_attach(e, false, a)`, `f !@ a` is `__lt_hook(f,
--   name, a)` with the name of the binding target or `nil`, and
--   `lifetime.scope` in anchor position is the record local of the
--   innermost enclosing block ("What `@` expands to").
-- * A block that anchors to `lifetime.scope` directly gets `local __sN =
--   __lt_enter("<chunk>:<line of its end>")` at its start and
--   `__lt_exit(__sN, "<chunk>:<line>")` on fall-through and before every
--   `return`, `break` and `goto` that leaves it ("Blocks: prologue and
--   epilogue on every exit path"). Every other block, and so every
--   function that does not anchor to `lifetime.scope`, is emitted
--   verbatim ("Functions").
--
-- Which blocks need a record is known only once the whole function has
-- been read (a `return` may leave a block whose `@ lifetime.scope` comes
-- after it), so a chunk that uses `lifetime.scope` is analysed first
-- (`analyse`). A chunk that does not is emitted in one pass: emission
-- starts without the analysis and starts over with it at the first
-- `lifetime.scope` it meets, so plain Lua pays no second walk. The
-- one-pass case is measured by `build/plain.lt`, `build/generated-5000`
-- and `build/lifetime-largest` in bench/bench-build.lua (`make bench`);
-- the restart by `build/extension-5000` (a `lifetime.scope` on line 3)
-- and `build/scope-at-end-5000` (on the last line: a whole emission
-- thrown away, then the analysis and the emission again; about 1.4 times
-- `build/generated-5000` on the same file under both interpreters, task
-- 007).

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

-- Raised by an emission without analysis at the first `lifetime.scope`
-- anchor: the chunk is analysed and emitted again.
local RESTART = {}

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

-- The output state: pieces (the first is reserved for the header), the
-- current line, the block depth and whether a statement is under way
-- (its continuation lines are indented one level deeper), the last token
-- and whether the next one is glued to it. `info` is the analysis or
-- nil; `scope` the record local of the innermost block, if it has one.
-- `shadow` counts the locals named `lifetime` in scope, `named` says the
-- chunk names the global `lifetime`; `attach`, `hook`, `record` and
-- `pack` say which runtime functions the generated code calls.
local function new_state(info)
    return {
        buf = {""},
        n = 1,
        line = 1,
        depth = 0,
        continued = false,
        last = nil,
        last_number = false,
        glue = false,
        info = info,
        open_end = 0,
        scope = nil,
        shadow = 0,
        named = false,
        attach = false,
        hook = false,
        record = false,
        pack = false
    }
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
-- later stage, a hook's name, a position): `%q`, with the line breaks
-- escaped so that it stays on one line.
local function quote(value)
    return (gsub(format("%q", value), "\\\n", "\\n"))
end

local function number_text(value)
    if value == math.floor(value) and value >= -2 ^ 53 and value <= 2 ^ 53 then
        return format("%d", value)
    end
    return format("%.17g", value)
end

-- A local comes into scope: count it if it shadows the global `lifetime`
-- (docs/04-transpiler.md, "The generated chunk header": "A source file
-- that shadows `lifetime` gets what it wrote"). `destroy` and `discard`
-- are ordinary names (docs/05-decisions.md, "`destroy` and `discard` are
-- spelled `lifetime.destroy` and `lifetime.discard`").
local function declare(st, name)
    if name == "lifetime" then
        st.shadow = st.shadow + 1
    end
end

-- The locals declared since `shadow` was `saved` go out of scope.
local function undeclare(st, saved)
    st.shadow = saved
end

-- A name being declared (a local, a parameter, a loop variable): written,
-- not counted as a use.
local function put_name(st, id)
    put(st, id.name, id.line)
end

------------------------------------------------------------------------
-- Analysis: which blocks need a scope record, and what every `return`,
-- `break` and `goto` must run before it leaves (docs/04-transpiler.md,
-- "Blocks: prologue and epilogue on every exit path").
------------------------------------------------------------------------

-- The line of a node's last token (its `end` or `until`).
local function last_line(node)
    local lines = node.lines
    return lines and lines[#lines] or node.line
end

-- The code that runs the epilogue of the block `bi` at `pos`.
local function exit_code(bi, pos)
    return "__lt_exit(" .. bi.record .. ", " .. pos .. "); "
end

-- Returns `{blocks = {[Block] = info}, exits = {[statement] = code}}`.
-- A block's info has `parent` (nil for a function body or the chunk),
-- `kind` ("function", "loop", "repeat" or "block"), `labels` (name to
-- statement index, or false) and, when it needs a record, `record` (the
-- local's name), `pos` (the quoted position of its end) and `trailing`
-- (the index of its first trailing label, if any). `exits[s]` is the code
-- that runs the epilogues the statement `s` must run before it leaves,
-- innermost first. Raises `chunkname:line: <goto NAME> jumps into the
-- scope of a lifetime`.
local function analyse(chunk, chunkname)
    local blocks, exits = {}, {}
    local pending, np = {}, 0
    local count = 0
    local cur, fn = nil, nil
    local walk_expr, walk_block

    local function pos_of(line)
        return quote(chunkname .. ":" .. tostring(line or "?"))
    end

    local function walk_list(list)
        for i = 1, #list do
            walk_expr(list[i])
        end
    end

    local function walk_function(f)
        local outer_cur, outer_fn = cur, fn
        cur, fn = nil, {labels = {}}
        walk_block(f.body, "function", last_line(f))
        cur, fn = outer_cur, outer_fn
    end

    function walk_expr(e)
        local tag = e.tag
        if tag == "Anchor" or tag == "Hook" then
            walk_expr(e.expr)
            local anchors = e.anchors
            for i = 1, #anchors do
                local item = anchors[i]
                if item.tag == "ScopeAnchor" then
                    -- docs/02-semantics.md, "Scopes: `lifetime.scope`":
                    -- "`lifetime.scope` after `@` is the innermost block
                    -- enclosing the `@`."
                    cur.scoped = true
                else
                    walk_expr(item)
                end
            end
        elseif tag == "Function" then
            walk_function(e)
        elseif tag == "Call" then
            walk_expr(e.func)
            walk_list(e.args)
        elseif tag == "Invoke" then
            walk_expr(e.obj)
            walk_list(e.args)
        elseif tag == "Member" then
            walk_expr(e.obj)
        elseif tag == "Index" then
            walk_expr(e.obj)
            walk_expr(e.key)
        elseif tag == "Paren" then
            walk_expr(e.expr)
        elseif tag == "BinOp" then
            walk_expr(e.left)
            walk_expr(e.right)
        elseif tag == "UnOp" then
            walk_expr(e.operand)
        elseif tag == "Table" then
            local fields = e.fields
            for i = 1, #fields do
                local field = fields[i]
                if field.key then
                    walk_expr(field.key)
                end
                walk_expr(field.value)
            end
        end
    end

    local function walk_stat(s, i)
        local tag = s.tag
        if tag == "Local" then
            walk_list(s.exprs)
        elseif tag == "Set" then
            walk_list(s.targets)
            walk_list(s.exprs)
        elseif tag == "CallStat" then
            walk_expr(s.call)
        elseif tag == "AnchorStat" or tag == "HookStat" then
            walk_expr(s.expr)
        elseif tag == "LocalFunction" then
            walk_function(s.func)
        elseif tag == "FunctionStat" then
            walk_expr(s.target)
            walk_function(s.func)
        elseif tag == "Do" then
            walk_block(s.body, "block", last_line(s))
        elseif tag == "While" then
            walk_expr(s.cond)
            walk_block(s.body, "loop", last_line(s))
        elseif tag == "Repeat" then
            walk_block(s.body, "repeat", last_line(s), s.cond)
        elseif tag == "If" then
            local conds, lines = s.conds, s.lines
            for j = 1, #conds do
                walk_expr(conds[j])
                -- The token after the j-th `then`: `elseif`, `else` or `end`.
                walk_block(s.blocks[j], "block", lines and lines[2 * j + 1] or s.line)
            end
            if s.else_block then
                walk_block(s.else_block, "block", last_line(s))
            end
        elseif tag == "NumericFor" then
            walk_expr(s.start)
            walk_expr(s.limit)
            if s.step then
                walk_expr(s.step)
            end
            walk_block(s.body, "loop", last_line(s))
        elseif tag == "GenericFor" then
            walk_list(s.exprs)
            walk_block(s.body, "loop", last_line(s))
        elseif tag == "Return" or tag == "Break" or tag == "Goto" then
            if tag == "Return" then
                walk_list(s.exprs)
            end
            np = np + 1
            pending[np] = {s, cur, fn}
        elseif tag == "Label" then
            local labels = cur.labels
            if not labels then
                labels = {}
                cur.labels = labels
            end
            labels[s.name] = i
            local defs = fn.labels[s.name]
            if not defs then
                defs = {}
                fn.labels[s.name] = defs
            end
            defs[#defs + 1] = cur
        end
    end

    function walk_block(b, kind, close, cond)
        local bi = {parent = cur, kind = kind, labels = false, scoped = false}
        blocks[b] = bi
        local outer = cur
        cur = bi
        for i = 1, #b do
            walk_stat(b[i], i)
        end
        if cond then
            -- `until` sees the body's locals: the condition is in the
            -- body's block (Lua 5.1 manual, §2.4.4).
            walk_expr(cond)
        end
        cur = outer
        if bi.scoped then
            count = count + 1
            bi.record = "__s" .. count
            bi.pos = pos_of(close)
            if kind ~= "repeat" then
                -- Labels at the end of a block, which a `goto` may reach
                -- over a local (LuaJIT, as Lua 5.2), stay at the end: the
                -- epilogue goes before them. LuaJIT never counts a label
                -- before `until` as one.
                local t = #b
                while t > 0 and b[t].tag == "Label" do
                    t = t - 1
                end
                if t < #b then
                    bi.trailing = t + 1
                end
            end
        end
    end

    fn = {labels = {}}
    walk_block(chunk, "function", chunk.lines and chunk.lines[1])

    for k = 1, np do
        local s, bi, f = pending[k][1], pending[k][2], pending[k][3]
        local tag = s.tag
        local pos = pos_of(s.line)
        local code, nc = {}, 0
        local b = bi
        if tag == "Return" then
            -- "every epilogue from the innermost block up to the function
            -- body runs, then the values are returned."
            while b do
                if b.record then
                    nc = nc + 1
                    code[nc] = exit_code(b, pos)
                end
                b = b.parent
            end
        elseif tag == "Break" then
            -- "the epilogues of the blocks between the `break` and the
            -- loop body it leaves, innermost first, then the `break`."
            while b do
                if b.record then
                    nc = nc + 1
                    code[nc] = exit_code(b, pos)
                end
                if b.kind == "loop" or b.kind == "repeat" then
                    break
                end
                b = b.parent
            end
        else
            -- "`goto` (LuaJIT): the epilogues of the blocks the jump
            -- leaves, innermost first." The target is the innermost
            -- enclosing block that defines the label: a label is visible
            -- in its block and in the blocks nested in it, not in a
            -- nested function.
            local name, chain, found = s.name, {}, false
            while b do
                chain[b] = true
                local index = b.labels and b.labels[name]
                if index then
                    found = true
                    if b.trailing and index >= b.trailing then
                        -- A trailing label sits after the epilogue: the
                        -- jump runs it as falling through to the end
                        -- would, with the position of the end.
                        nc = nc + 1
                        code[nc] = exit_code(b, b.pos)
                    end
                    break
                end
                if b.record then
                    nc = nc + 1
                    code[nc] = exit_code(b, pos)
                end
                b = b.parent
            end
            if not found then
                -- "A `goto` into a block that needs a record is a compile
                -- error ("jumps into the scope of a lifetime")": a label
                -- of this function, invisible from the `goto`, in or
                -- under a block with a record that does not enclose it.
                -- Any other invisible label is LuaJIT's to report.
                nc = 0
                local defs = f.labels[name]
                for j = 1, defs and #defs or 0 do
                    local d = defs[j]
                    while d and not chain[d] do
                        if d.record then
                            error(chunkname .. ":" .. s.line .. ": <goto " .. name .. "> jumps into the scope of a lifetime", 0)
                        end
                        d = d.parent
                    end
                end
            end
        end
        if nc > 0 then
            exits[s] = concat(code, "", 1, nc)
        end
    end

    return {blocks = blocks, exits = exits}
end

------------------------------------------------------------------------
-- Emission
------------------------------------------------------------------------

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
-- `function` and `(` in a statement; `local_name` is the Id a `local
-- function` declares, in scope in the body. The body is a block
-- (docs/04-transpiler.md, "Functions": "A function body is a block and
-- gets code only under the block rule"): nothing is added to the
-- function itself.
local function emit_function(st, f, name, method, stat, local_name)
    local lines = f.lines
    put(st, "function", lines and lines[1])
    if local_name then
        put_name(st, local_name)
        declare(st, local_name.name)
    elseif name then
        emit_expr(st, name)
        if method then
            local slines = stat.lines
            put(st, ":", slines and slines[1], true, true)
            put(st, method, slines and slines[2])
        end
    end
    put(st, "(", lines and lines[2], true, true)
    local saved = st.shadow
    local k = 2
    local params = f.params
    for i = 1, #params do
        if i > 1 then
            k = k + 1
            put(st, ",", lines and lines[k], true)
        end
        put_name(st, params[i])
        declare(st, params[i].name)
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
    emit_block(st, f.body, lines and lines[k + 2])
    undeclare(st, saved)
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

-- A name used as an expression or an assignment target. The global
-- `lifetime` named is bound by the header ("an assignment target counts
-- as naming it").
EXPR.Id = function(st, e)
    local name = e.name
    if name == "lifetime" and st.shadow == 0 then
        st.named = true
    end
    put(st, name, e.line)
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

-- docs/04-transpiler.md, "What `@` expands to": `e @ (a1, …, an)` is
-- `__lt_attach(e, false, a1, …, an)` and `f !@ (a1, …, an)` is
-- `__lt_hook(f, name, a1, …, an)`, `name` being the quoted name of the
-- binding target or `nil` (docs/02-semantics.md, "Named hooks"). The call
-- starts on the line of the left operand; the comma after it takes the
-- line of the operator, the list's parentheses and commas theirs. `x @
-- (a)` and `x @ a` come out alike. An anchor item is one value
-- (docs/02-semantics.md, "Acquiring a lifetime": "Evaluate each
-- element"), so a call or `...` as the last item is parenthesised to one.
local function emit_anchor(st, e, hook)
    local lines = e.lines
    if hook then
        st.hook = true
        put(st, "__lt_hook", e.line)
    else
        st.attach = true
        put(st, "__lt_attach", e.line)
    end
    put(st, "(", nil, true, true)
    emit_expr(st, e.expr)
    put(st, ",", lines and lines[1], true)
    if hook then
        put(st, e.name and quote(e.name) or "nil")
    else
        put(st, "false")
    end
    local anchors, list = e.anchors, e.list and lines
    local n = #anchors
    for i = 1, n do
        -- Item i follows the list's `(` (i = 1) or its (i - 1)-th comma.
        put(st, ",", list and lines[i + 1], true)
        local item = anchors[i]
        local tag = item.tag
        if i == n and (tag == "Call" or tag == "Invoke" or tag == "Vararg") then
            put(st, "(", nil, false, true)
            emit_expr(st, item)
            put(st, ")", nil, true)
        else
            emit_expr(st, item)
        end
    end
    put(st, ")", list and lines[n + 2], true)
    st.open_end = st.n
end

EXPR.Anchor = function(st, e)
    emit_anchor(st, e, false)
end

EXPR.Hook = function(st, e)
    emit_anchor(st, e, true)
end

-- `lifetime.scope` in anchor position: the record of the innermost
-- enclosing block (docs/04-transpiler.md, "What `@` expands to": "`e @
-- lifetime.scope` | `__lt_attach(e, false, <scope local>)`").
EXPR.ScopeAnchor = function(st, e)
    local record = st.scope
    if not record then
        if st.info then
            error("emit: lifetime.scope in a block without a record", 2)
        end
        error(RESTART, 0)
    end
    put(st, record, e.line)
end

function emit_expr(st, e)
    local f = EXPR[e.tag]
    if not f then
        error("emit: unknown expression node '" .. tostring(e.tag) .. "'", 2)
    end
    f(st, e)
end

-- The code a `return`, `break` or `goto` runs before it leaves, or nil.
local function exits_of(st, s)
    local info = st.info
    return info and info.exits[s]
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
        put_name(st, names[i])
    end
    if #s.exprs > 0 then
        k = k + 1
        put(st, "=", lines and lines[k])
        emit_explist(st, s.exprs, s, k)
    end
    -- The values are evaluated before the names come into scope.
    for i = 1, #names do
        declare(st, names[i].name)
    end
end

STAT.LocalFunction = function(st, s)
    put(st, "local", s.lines and s.lines[1])
    emit_function(st, s.func, nil, nil, nil, s.name)
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
    emit_block(st, s.body, lines and lines[2])
    put(st, "end", lines and lines[2])
end

STAT.While = function(st, s)
    local lines = s.lines
    put(st, "while", lines and lines[1])
    emit_expr(st, s.cond)
    put(st, "do", lines and lines[2])
    emit_block(st, s.body, lines and lines[3])
    put(st, "end", lines and lines[3])
end

-- `until` and its condition are written by emit_block, inside the body's
-- scope.
STAT.Repeat = function(st, s)
    put(st, "repeat", s.lines and s.lines[1])
    emit_block(st, s.body, s.lines and s.lines[2], s)
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
        emit_block(st, blocks[i], lines and lines[k + 1])
    end
    if s.else_block then
        k = k + 1
        put(st, "else", lines and lines[k])
        emit_block(st, s.else_block, lines and lines[k + 1])
    end
    put(st, "end", lines and lines[k + 1])
end

STAT.NumericFor = function(st, s)
    local lines = s.lines
    put(st, "for", lines and lines[1])
    put_name(st, s.var)
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
    local saved = st.shadow
    declare(st, s.var.name)
    emit_block(st, s.body, lines and lines[k + 2])
    undeclare(st, saved)
    put(st, "end", lines and lines[k + 2])
end

STAT.GenericFor = function(st, s)
    local lines = s.lines
    local vars = s.vars
    put(st, "for", lines and lines[1])
    local k = 1
    for i = 1, #vars do
        if i > 1 then
            k = k + 1
            put(st, ",", lines and lines[k], true)
        end
        put_name(st, vars[i])
    end
    k = k + 1
    put(st, "in", lines and lines[k])
    k = emit_explist(st, s.exprs, s, k)
    put(st, "do", lines and lines[k + 1])
    local saved = st.shadow
    for i = 1, #vars do
        declare(st, vars[i].name)
    end
    emit_block(st, s.body, lines and lines[k + 2])
    undeclare(st, saved)
    put(st, "end", lines and lines[k + 2])
end

-- docs/04-transpiler.md, "Blocks": "**`return explist`** inside the block
-- ...: the values are evaluated first, then every epilogue from the
-- innermost block up to the function body runs, then the values are
-- returned. Trailing `nil`s survive by packing with `select("#", …)` and
-- unpacking with `unpack(t, 1, n)`." Only a list that ends in a call or
-- `...` has a number of values the emitter cannot see, and only it is
-- packed; a fixed number of values goes to as many locals, `nil`s
-- included. The `return` stays the last statement of its block, as Lua
-- requires.
STAT.Return = function(st, s)
    local line = s.lines and s.lines[1]
    local exprs = s.exprs
    local n = #exprs
    local exits = exits_of(st, s)
    if not exits then
        put(st, "return", line)
        emit_explist(st, exprs, s, 1)
    elseif n == 0 then
        put(st, exits .. "return", line)
    else
        local tag = exprs[n].tag
        if tag == "Call" or tag == "Invoke" or tag == "Vararg" then
            st.pack = true
            put(st, "local __r = __lt_pack(", line, false, true)
            emit_explist(st, exprs, s, 1)
            put(st, "); " .. exits .. "return __lt_unpack(__r, 1, __r.n)", nil, true)
        else
            local names = {}
            for i = 1, n do
                names[i] = "__r" .. i
            end
            names = concat(names, ", ")
            put(st, "local " .. names .. " =", line)
            emit_explist(st, exprs, s, 1)
            put(st, "; " .. exits .. "return " .. names, nil, true)
        end
    end
end

-- "**`break`**: the epilogues of the blocks between the `break` and the
-- loop body it leaves, innermost first, then the `break`."
STAT.Break = function(st, s)
    put(st, (exits_of(st, s) or "") .. "break", s.lines and s.lines[1])
end

-- LuaJIT's `goto` and labels, as written (CLAUDE.md, "Technical
-- decisions": "LuaJIT's `goto` is honoured by the transpiler when it
-- appears in the input"), after the epilogues of the blocks the jump
-- leaves.
STAT.Goto = function(st, s)
    local lines = s.lines
    put(st, (exits_of(st, s) or "") .. "goto", lines and lines[1])
    put(st, s.name, lines and lines[2])
end

STAT.Label = function(st, s)
    local lines = s.lines
    put(st, "::", lines and lines[1], false, true)
    put(st, s.name, lines and lines[2])
    put(st, "::", lines and lines[3], true)
end

-- The statement forms of `@` and `!@` are the same calls as statements
-- ("`x @ a` as a statement | the same call as a statement"); a chain is
-- nested calls whatever its outermost operator.
STAT.AnchorStat = function(st, s)
    emit_expr(st, s.expr)
end

STAT.HookStat = STAT.AnchorStat

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

-- Does the statement's output start with `(`? A Set or a call statement
-- whose leftmost prefixexp is parenthesised; the forms of `@` and `!@`
-- start with the name of a runtime function.
local function starts_with_paren(s)
    local tag = s.tag
    local e
    if tag == "CallStat" then
        e = s.call
    elseif tag == "Set" then
        e = s.targets[1]
    else
        return false
    end
    while true do
        tag = e.tag
        if tag == "Paren" then
            return true
        elseif tag == "Call" then
            e = e.func
        elseif tag == "Invoke" or tag == "Member" or tag == "Index" then
            e = e.obj
        else
            return false
        end
    end
end

-- The epilogue of a block on fall-through, at `line`.
local function put_epilogue(st, bi, line)
    st.continued = false
    advance(st, line)
    put(st, "__lt_exit(" .. bi.record .. ", " .. bi.pos .. ");")
end

-- The statements of a block, `indent` levels deeper, and what the block
-- needs around them (docs/04-transpiler.md, "Blocks: prologue and
-- epilogue on every exit path"): for a block with a record, `local __sN =
-- __lt_enter(<position of its end>)` on the line that opens it, and the
-- epilogue on fall-through at `close` (the line of the token that ends
-- it), or before its trailing labels. A block that ends with `return` or
-- `break` has no fall-through. `repeat_stat` is the `repeat` whose body
-- this is: its `until` and condition are written here, inside the body's
-- scope, and with a record the condition is evaluated before the
-- epilogue (`local __u = cond; __lt_exit(…); until __u`). No closure, no
-- `pcall`: the error path is the runtime's ("The error path: unwinding at
-- the catch site").
local function emit_scope(st, b, close, repeat_stat, indent)
    local info = st.info
    local bi = info and info.blocks[b]
    local record = bi and bi.record
    local outer = st.scope
    st.scope = record
    local saved = st.shadow
    st.depth = st.depth + indent
    if record then
        st.record = true
        put(st, "local " .. record .. " = __lt_enter(" .. bi.pos .. ");")
    end
    local n = #b
    local trailing = record and bi.trailing
    for i = 1, (trailing or n + 1) - 1 do
        emit_statement(st, b[i])
        -- Generated code that ends a statement with a call's `)` or a
        -- name, before a statement starting with `(` on a later line,
        -- would be Lua 5.1's "ambiguous syntax (function call x new
        -- statement)": a `;` keeps them apart.
        if st.open_end == st.n and i < n and starts_with_paren(b[i + 1]) then
            put(st, ";", nil, true)
        end
    end
    local last = b[n]
    local falls = not (last and (last.tag == "Return" or last.tag == "Break"))
    if trailing then
        put_epilogue(st, bi, b[trailing].line)
        for i = trailing, n do
            emit_statement(st, b[i])
        end
    end
    st.depth = st.depth - indent
    st.continued = false
    if repeat_stat then
        local line = repeat_stat.lines and repeat_stat.lines[2]
        if record and falls then
            advance(st, line)
            put(st, "local __u =")
            st.continued = true
            emit_expr(st, repeat_stat.cond)
            put(st, "; __lt_exit(" .. record .. ", " .. bi.pos .. "); until __u", nil, true)
            st.open_end = st.n
        else
            put(st, "until", line)
            st.continued = true
            emit_expr(st, repeat_stat.cond)
        end
    elseif record and falls and not trailing then
        put_epilogue(st, bi, close)
    end
    undeclare(st, saved)
    st.scope = outer
end

-- The statements of a block, one indentation level deeper.
function emit_block(st, b, close, repeat_stat)
    emit_scope(st, b, close, repeat_stat, 1)
    st.continued = false
end

-- docs/04-transpiler.md, "The generated chunk header": one line, the
-- first, that binds the runtime and the runtime functions the chunk
-- calls to locals, naming only what the chunk uses; nil for a chunk that
-- uses no extension syntax and does not name `lifetime`. "There are no
-- builtins".
local function header(st)
    if not (st.attach or st.hook or st.record or st.named) then
        return nil
    end
    local parts = {"local lifetime = require(\"lifetime\");"}
    local names, values = {}, {}
    local function bind(name)
        names[#names + 1] = "__lt_" .. name
        values[#values + 1] = "lifetime." .. name
    end
    if st.attach then
        bind("attach")
    end
    if st.hook then
        bind("hook")
    end
    if st.record then
        bind("enter")
        bind("exit")
    end
    if #names > 0 then
        parts[#parts + 1] = "local " .. concat(names, ", ") .. " = " .. concat(values, ", ") .. ";"
    end
    if st.pack then
        parts[#parts + 1] = "local __lt_unpack, __lt_select = unpack, select; local function __lt_pack(...) return {n = __lt_select(\"#\", ...), ...} end;"
    end
    return concat(parts, " ")
end

-- The chunk, with the analysis `info` or without it.
local function emit_chunk(ast, info)
    local st = new_state(info)
    local close = ast.lines and ast.lines[1]
    -- "The main chunk is a block like any other"; its end is <eof>.
    emit_scope(st, ast, close, nil, 0)
    if ast.lines then
        -- Up to the line of <eof>, so that the output has the source's
        -- number of lines (LuaJIT records it in the main function).
        st.continued = false
        advance(st, close)
    elseif st.n > 1 then
        st.n = st.n + 1
        st.buf[st.n] = "\n"
    end
    local text = header(st)
    if text then
        local first = st.buf[2]
        st.buf[1] = (first and byte(first, 1) ~= 10) and text .. " " or text
    end
    return concat(st.buf, "", 1, st.n)
end

-- Emit a chunk (the Block that parser.parse returns) as Lua source.
-- `chunkname` is the name positions are reported under (`"?"` if
-- omitted), as given to lifetime/cli.lua's `build`. Raises
-- `chunkname:line: <goto NAME> jumps into the scope of a lifetime` for a
-- `goto` into a block that needs a record (docs/04-transpiler.md,
-- "Blocks").
function emit.emit(ast, chunkname)
    local ok, result = pcall(emit_chunk, ast, nil)
    if ok then
        return result
    end
    if result ~= RESTART then
        error(result, 0)
    end
    return emit_chunk(ast, analyse(ast, chunkname or "?"))
end

return emit
