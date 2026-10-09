-- tests/test-parser.lua: lifetime/parser.lua (task 001). Every production
-- of the manual's §8 parses to the AST lifetime/parser.lua documents, with
-- a line on every node; syntax errors come in the wording and at the line
-- of Lua 5.1's lparser.c.
local test = require("tests.lib.test")
local lexer = require("lifetime.lexer")
local parser = require("lifetime.parser")
local chunks = require("tests.lib.chunks")

local function parse(source)
    return parser.parse(lexer.tokenize(source, "t", true), "t")
end

-- A compact rendering of an expression, fully parenthesised, so that a
-- test can state the shape of the tree in one string.
local show

local function show_list(list)
    local parts = {}
    for i = 1, #list do
        parts[i] = show(list[i])
    end
    return table.concat(parts, ", ")
end

local function show_args(e)
    if e.sugar then
        return " " .. show(e.args[1])
    end
    return "(" .. show_list(e.args) .. ")"
end

function show(e)
    local tag = e.tag
    if tag == "Id" then
        return e.name
    elseif tag == "Number" or tag == "String" then
        return e.raw
    elseif tag == "Nil" or tag == "True" or tag == "False" then
        return tag:lower()
    elseif tag == "Vararg" then
        return "..."
    elseif tag == "BinOp" then
        return "(" .. show(e.left) .. " " .. e.op .. " " .. show(e.right) .. ")"
    elseif tag == "UnOp" then
        return "(" .. e.op .. (e.op == "not" and " " or "") .. show(e.operand) .. ")"
    elseif tag == "Paren" then
        return "P(" .. show(e.expr) .. ")"
    elseif tag == "Member" then
        return show(e.obj) .. "." .. e.name
    elseif tag == "Index" then
        return show(e.obj) .. "[" .. show(e.key) .. "]"
    elseif tag == "Call" then
        return show(e.func) .. show_args(e)
    elseif tag == "Invoke" then
        return show(e.obj) .. ":" .. e.method .. show_args(e)
    elseif tag == "Function" then
        local params = {}
        for i = 1, #e.params do
            params[i] = e.params[i].name
        end
        if e.is_vararg then
            params[#params + 1] = "..."
        end
        return "function(" .. table.concat(params, ", ") .. ")"
    elseif tag == "Table" then
        local fields = {}
        for i, field in ipairs(e.fields) do
            if field.tag == "NameField" then
                fields[i] = field.name .. " = " .. show(field.value)
            elseif field.tag == "KeyField" then
                fields[i] = "[" .. show(field.key) .. "] = " .. show(field.value)
            else
                fields[i] = show(field.value)
            end
        end
        return "{" .. table.concat(fields, ", ") .. "}"
    elseif tag == "Anchor" or tag == "Hook" then
        -- `(e @ a)`, `(e @ (a, b))`; a Hook bound to a name shows it as
        -- `(f !@[name] a)`.
        local op = tag == "Anchor" and "@" or "!@"
        if e.name then
            op = op .. "[" .. e.name .. "]"
        end
        local anchors = show_list(e.anchors)
        if e.list then
            anchors = "(" .. anchors .. ")"
        end
        return "(" .. show(e.expr) .. " " .. op .. " " .. anchors .. ")"
    elseif tag == "ScopeAnchor" then
        return "SCOPE"
    end
    error("show: unexpected node " .. tostring(tag))
end

-- The expression `x[1] = <source>` assigns (to an Index, which names no
-- hook).
local function expression(source)
    local chunk = parse("x[1] = " .. source)
    return show(chunk[1].exprs[1])
end

-- Every node of the tree: every table with a `tag`.
local function each_node(node, fn)
    if type(node) ~= "table" then
        return
    end
    if node.tag then
        fn(node)
    end
    for k, v in pairs(node) do
        if k ~= "lines" then
            each_node(v, fn)
        end
    end
end

test.suite("parser")

test.case("the chunk with every form of §8 parses, statement by statement", function()
    local chunk = parse(chunks.EVERY_FORM)
    local tags = {}
    for i = 1, #chunk do
        tags[i] = chunk[i].tag
    end
    test.assert_deep_eq(tags, {
        "Local", "LocalFunction", "FunctionStat", "FunctionStat", "Set", "Set", "Do", "While", "Repeat", "If", "If", "NumericFor", "NumericFor",
        "GenericFor", "GenericFor", "CallStat", "CallStat", "CallStat", "CallStat", "CallStat", "CallStat", "CallStat", "Set", "Set", "Set", "Set",
        "Set", "Set", "Set", "Set", "Set", "Set", "Set", "Set", "Set", "Set", "LocalFunction", "LocalFunction", "Local", "Set", "Local", "Return"
    })
end)

test.case("every statement starts on its source line", function()
    local chunk = parse(chunks.EVERY_FORM)
    local lines = {}
    for i = 1, #chunk do
        lines[i] = chunk[i].line
    end
    test.assert_deep_eq(lines, chunks.EVERY_FORM_STATEMENT_LINES)
end)

test.case("a line on every node", function()
    local count = 0
    each_node(parse(chunks.EVERY_FORM), function(node)
        count = count + 1
        test.assert_eq(type(node.line), "number", "line of a " .. node.tag)
        for _, line in ipairs(node.lines or {}) do
            test.assert_eq(type(line), "number", "lines of a " .. node.tag)
        end
    end)
    test.assert_true(count > 300, "the walk saw " .. count .. " nodes")
end)

test.case("local, local function, function t.a.b:c()", function()
    local chunk = parse(chunks.EVERY_FORM)
    test.assert_eq(chunk[1].names[3].name, "c")
    test.assert_eq(show_list(chunk[1].exprs), "1, 0x1F, 3.5e-2")
    test.assert_eq(chunk[2].name.name, "f")
    test.assert_eq(show(chunk[2].func), "function(x, y, ...)")
    test.assert_eq(show_list(chunk[2].func.body[1].exprs), "x, y, ...")
    local method = chunk[3]
    test.assert_eq(show(method.target), "t.a.b")
    test.assert_eq(method.method, "c")
    test.assert_eq(show(method.func), "function(p)")
    test.assert_true(method.func.is_method)
    test.assert_eq(show_list(method.func.body[1].exprs), "self, p")
    test.assert_eq(chunk[4].func.body[1].semi, 4)
    test.assert_eq(chunk[4].func.body[2].semi, 4)
    test.assert_eq(#chunk[7].body[1].exprs, 0)
    test.assert_eq(#chunk[37].func.body[1].exprs, 0)
end)

test.case("assignments: a.b[c] = d, e and several targets", function()
    local chunk = parse(chunks.EVERY_FORM)
    test.assert_eq(show_list(chunk[5].targets), "a.b[c]")
    test.assert_eq(show_list(chunk[5].exprs), "d, e")
    test.assert_eq(show_list(chunk[6].targets), "x, y.z, w[1]")
    test.assert_eq(show_list(chunk[6].exprs), "f(1), \"s\", [[long]]")
end)

test.case("control structures", function()
    local chunk = parse(chunks.EVERY_FORM)
    test.assert_eq(chunk[8].body[1].tag, "Break")
    test.assert_eq(show(chunk[9].cond), "(a <= 0)")
    test.assert_eq(show(chunk[9].body[1].exprs[1]), "(a - 1)")
    local branches = chunk[10]
    test.assert_eq(show_list(branches.conds), "a, c, d")
    test.assert_eq(#branches.blocks, 3)
    test.assert_eq(show(branches.else_block[1].exprs[1]), "4")
    test.assert_eq(chunk[11].else_block, nil)
    test.assert_eq(show_list({chunk[12].start, chunk[12].limit, chunk[12].step}), "1, 10, 2")
    test.assert_eq(chunk[13].step, nil)
    test.assert_eq(chunk[13].var.name, "i")
    local generic = chunk[14]
    test.assert_eq(generic.vars[1].name .. "," .. generic.vars[2].name, "k,v")
    test.assert_eq(show_list(generic.exprs), "pairs(t)")
    test.assert_eq(show_list(chunk[15].exprs), "next, t, nil")
end)

test.case("calls: method calls, string-call and table-call sugar, prefixes", function()
    local chunk = parse(chunks.EVERY_FORM)
    local calls = {}
    for i = 16, 22 do
        calls[#calls + 1] = show(chunk[i].call)
    end
    test.assert_deep_eq(calls, {
        "obj:method(1, 2)", "obj.field:method \"str\"", "obj:method {1, 2}", "print 'hello'", "print {x = 1, [2] = 3, 4}", "f()()", "P(f)(1)"
    })
    test.assert_deep_eq(chunk[20].call.args[1].seps, {",", ";", ","})
    test.assert_eq(chunk[21].semi, 21)
    test.assert_eq(show(chunk[23].exprs[1]), "P(f())")
    test.assert_eq(show(chunk[29].exprs[1]), "f {...}[1].y:z(...)")
    test.assert_eq(show(chunk[41].exprs[1]), "t.field[key]:method(1, 2)")
end)

test.case("functions and tables as expressions", function()
    local chunk = parse(chunks.EVERY_FORM)
    test.assert_eq(show(chunk[24].exprs[1]), "function(...)")
    test.assert_eq(show_list(chunk[24].exprs[1].body[1].exprs), "...")
    test.assert_eq(show(chunk[25].exprs[1]), "function()")
    test.assert_eq(show(chunk[26].exprs[1]), "{}")
    test.assert_eq(show(chunk[27].exprs[1]), "{1, 2, 3}")
    test.assert_deep_eq(chunk[27].exprs[1].seps, {",", ",", ","})
    test.assert_eq(show(chunk[28].exprs[1]), "{f()}")
end)

test.case("literals", function()
    local chunk = parse(chunks.EVERY_FORM)
    test.assert_eq(show_list(chunk[34].exprs), "true, false, nil, ...")
    local strings = chunk[35].exprs[1]
    test.assert_eq(strings.left.value, "single")
    test.assert_eq(strings.right.left.value, "double\n\t\\\"")
    test.assert_eq(strings.right.right.value, " level ]] two ")
    local numbers = {}
    for i, e in ipairs(chunk[36].exprs) do
        numbers[i] = e.value
    end
    test.assert_deep_eq(numbers, {1, 1.5, 0.5, 5, 1e10, 0.01, 255, 10})
end)

test.case("every operator at every precedence level", function()
    -- lparser.c, `priority` and UNARY_PRIORITY; manual §2.5.6.
    test.assert_eq(expression("a or b and c < d .. e + f * -g ^ h"), "(a or (b and (c < (d .. (e + (f * (-(g ^ h))))))))")
    test.assert_eq(expression("h ^ -g * f + e .. d < c and b or a"), "(((((((h ^ (-g)) * f) + e) .. d) < c) and b) or a)")
    test.assert_eq(expression("a == b ~= c < d <= e > f >= g"), "((((((a == b) ~= c) < d) <= e) > f) >= g)")
    test.assert_eq(expression("a + b - c"), "((a + b) - c)")
    test.assert_eq(expression("a * b / c % d"), "(((a * b) / c) % d)")
    test.assert_eq(expression("a .. b .. c"), "(a .. (b .. c))")
    test.assert_eq(expression("a ^ b ^ c"), "(a ^ (b ^ c))")
    test.assert_eq(expression("a or b or c"), "((a or b) or c)")
    test.assert_eq(expression("a and b or c and d"), "((a and b) or (c and d))")
    test.assert_eq(expression("a + b .. c + d"), "((a + b) .. (c + d))")
    test.assert_eq(expression("not a == b"), "((not a) == b)")
    test.assert_eq(expression("#t + 1"), "((#t) + 1)")
    test.assert_eq(expression("- - a"), "(-(-a))")
    test.assert_eq(expression("-a ^ b"), "(-(a ^ b))")
    test.assert_eq(expression("2 ^ -3 ^ 2"), "(2 ^ (-(3 ^ 2)))")
    test.assert_eq(expression("(a + b) * c"), "(P((a + b)) * c)")
end)

test.case("the lines of a node's own tokens", function()
    local chunk = parse(chunks.EVERY_FORM)
    local call = chunk[41].exprs[1]
    test.assert_eq(call.tag, "Invoke")
    test.assert_deep_eq(call.lines, {46, 46, 46, 47, 49}) -- : method ( , )
    test.assert_deep_eq(call.obj.lines, {43, 45}) -- [ ]
    test.assert_deep_eq(call.obj.obj.lines, {42, 42}) -- . field
    test.assert_eq(call.obj.key.line, 44)
    test.assert_deep_eq(chunk[10].lines, {10, 10, 10, 10, 10, 10, 10, 10}) -- if then elseif then elseif then else end
    test.assert_deep_eq(chunk.lines, {51}) -- <eof>
end)

-- Exact messages of Lua 5.1 (`loadstring(source, "=t")` under lua5.1).
local ERRORS = {
    {"local x = = 1", "t:1: unexpected symbol near '='"},
    {"x =\n", "t:2: unexpected symbol near '<eof>'"},
    {"(x)", "t:1: syntax error near '<eof>'"},
    {"(x) = 1", "t:1: syntax error near '='"},
    {"x", "t:1: '=' expected near '<eof>'"},
    {"f() = 1", "t:1: unexpected symbol near '='"},
    {"x, f() = 1", "t:1: syntax error near '='"},
    {"x, (y) = 1, 2", "t:1: syntax error near '='"},
    {"function f(a b) end", "t:1: ')' expected near 'b'"},
    {"function f(a,) end", "t:1: <name> or '...' expected near ')'"},
    {"function f(..., a) end", "t:1: ')' expected near ','"},
    {"local function f\n(\n a", "t:3: ')' expected near '<eof>'"},
    {"f\n(x)", "t:2: ambiguous syntax (function call x new statement) near '('"},
    {"x = g\n(f)()", "t:2: ambiguous syntax (function call x new statement) near '('"},
    {"break", "t:1: no loop to break near '<eof>'"},
    {"while 1 do break; x = 1 end", "t:1: 'end' expected near 'x'"},
    {"while true do local function f() break end end", "t:1: no loop to break near 'end'"},
    {"return; x", "t:1: '<eof>' expected near 'x'"},
    {"do return 1 end end", "t:1: '<eof>' expected near 'end'"},
    {"function f() return ... end", "t:1: cannot use '...' outside a vararg function near '...'"},
    {"local 1", "t:1: '<name>' expected near '1'"},
    {"for x do end", "t:1: '=' or 'in' expected near 'do'"},
    {"for i = 1 do end", "t:1: ',' expected near 'do'"},
    {"for a, b = 1, 2 do end", "t:1: 'in' expected near '='"},
    {"f:m", "t:1: function arguments expected near '<eof>'"},
    {"x = a.1", "t:1: unexpected symbol near '.1'"},
    {"x.y:z", "t:1: function arguments expected near '<eof>'"},
    {"if x then", "t:1: 'end' expected near '<eof>'"},
    {"if x then\n\nelse", "t:3: 'end' expected (to close 'if' at line 1) near '<eof>'"},
    {"while x end", "t:1: 'do' expected near 'end'"},
    {"repeat x = 1", "t:1: 'until' expected near '<eof>'"},
    {"x = {[1] 2}", "t:1: '=' expected near '2'"},
    {"x = {a = }", "t:1: unexpected symbol near '}'"},
    {"x = {1, 2\n\n", "t:3: '}' expected (to close '{' at line 1) near '<eof>'"},
    {"f(x\n\n", "t:3: ')' expected (to close '(' at line 1) near '<eof>'"},
    {"x = (1\n", "t:2: ')' expected (to close '(' at line 1) near '<eof>'"},
    {"x = \"a\" \"b\"", "t:1: unexpected symbol near '\"b\"'"},
    {"a.b = ", "t:1: unexpected symbol near '<eof>'"},
    {"return return", "t:1: unexpected symbol near 'return'"},
    {"function a.b:c.d() end", "t:1: '(' expected near '.'"},
    {"x = 1 // 2", "t:1: unexpected symbol near '/'"},
    {"local x <const> = 1", "t:1: unexpected symbol near '<'"},
    {"x = \0", "t:1: unexpected symbol"},
    {"x = \1", "t:1: unexpected symbol near 'char(1)'"},
    {"x = [[a\nb]] + +", "t:2: unexpected symbol near '+'"},
    -- The lookahead of a table constructor exempts only the token right
    -- after a Name that starts a field (review round 1, F1).
    {"x = { f\n(x) = 1 }", "t:2: '}' expected (to close '{' at line 1) near '='"},
    {"x = { f.g\n(x) }", "t:2: ambiguous syntax (function call x new statement) near '('"},
    {"x = { a = f\n(x) }", "t:2: ambiguous syntax (function call x new statement) near '('"},
    {"x = { f\n(x)\n(y) }", "t:3: ambiguous syntax (function call x new statement) near '('"},
    -- A malformed token is reported when the parser reaches it, so an
    -- earlier syntax error wins, as in Lua (deferred lexing).
    {"x = = \"abc", "t:1: unexpected symbol near '='"},
    {"x = 1 .. 0x", "t:1: malformed number near '0x'"},
    {"\"abc", "t:1: unfinished string near '<eof>'"}
}

test.case("a Name in a table constructor followed by `(` on a later line is a call", function()
    -- lparser.c, constructor: luaX_lookahead moves Lua's line past the
    -- token after the Name, so funcargs sees no new line there. Lua 5.1
    -- and LuaJIT both accept these chunks.
    test.assert_eq(expression("{ f\n(x) }"), "{f(x)}")
    test.assert_eq(expression("{ f\n\n(1) }"), "{f(1)}")
    test.assert_eq(expression("{ f\n(x), g\n(y) }"), "{f(x), g(y)}")
    test.assert_eq(expression("{ 1, f\n(x) }"), "{1, f(x)}")
    test.assert_eq(show(parse("t = { f\n\n(1) }")[1].exprs[1]), "{f(1)}")
end)

test.case("syntax errors in Lua 5.1's wording, at Lua's line", function()
    for _, case in ipairs(ERRORS) do
        local ok, err = pcall(parse, case[1])
        test.assert_false(ok, "expected an error for " .. string.format("%q", case[1]))
        test.assert_eq(err, case[2], string.format("%q", case[1]))
    end
end)

test.case("the parser takes the tokens tokenize returns", function()
    local chunk = parser.parse(lexer.tokenize("return 1", "t"), "t")
    test.assert_eq(chunk.tag, "Block")
    test.assert_eq(show_list(chunk[1].exprs), "1")
end)

-- Task 005: the extension (docs/04-transpiler.md, "Grammar";
-- docs/02-semantics.md, "Acquiring a lifetime", "Scopes:
-- `lifetime.scope`", "Hooks: the `!@` operator") and LuaJIT's `goto` and
-- labels.

-- The statement `source` parses to, shown: the operation of an AnchorStat
-- or a HookStat prefixed by its tag, the values of a Local or a Set, the
-- tag of anything else.
local function statement(source, index)
    local s = parse(source)[index or 1]
    if s.tag == "AnchorStat" or s.tag == "HookStat" then
        return s.tag .. " " .. show(s.expr)
    elseif s.tag == "Local" or s.tag == "Set" then
        return show_list(s.exprs)
    end
    return s.tag
end

local function assert_syntax_error(source, expected)
    local ok, err = pcall(parse, source)
    test.assert_false(ok, "expected an error for " .. string.format("%q", source))
    test.assert_eq(err, expected, string.format("%q", source))
end

test.case("`@` with one anchor, a list, `lifetime.scope`, and `lifetime.scope` in a list", function()
    test.assert_eq(expression("e @ a"), "(e @ a)")
    test.assert_eq(expression("e @ (a, b, c)"), "(e @ (a, b, c))")
    test.assert_eq(expression("e @ lifetime.scope"), "(e @ SCOPE)")
    test.assert_eq(expression("e @ (a, lifetime.scope)"), "(e @ (a, SCOPE))")
    local node = parse("x = e @ (a, lifetime.scope)")[1].exprs[1]
    test.assert_eq(node.tag, "Anchor")
    test.assert_eq(node.expr.name, "e")
    test.assert_eq(#node.anchors, 2)
    test.assert_eq(node.anchors[1].tag, "Id")
    test.assert_eq(node.anchors[2].tag, "ScopeAnchor")
    test.assert_true(node.list)
    test.assert_eq(parse("x = e @ lifetime.scope")[1].exprs[1].list, nil)
    -- A one-element list is the plain form (docs/02-semantics.md,
    -- "Acquiring a lifetime": "`x @ (a)` is `x @ a`, so ...
    -- `x @ (cond and a or b)`, keeps working").
    test.assert_eq(expression("e @ (a)"), "(e @ (a))")
    test.assert_eq(parse("x = e @ (a)")[1].exprs[1].anchors[1].tag, "Id")
    test.assert_eq(expression("e @ (cond and a or b)"), "(e @ (((cond and a) or b)))")
    test.assert_eq(parse("x = e @ (cond and a or b)")[1].exprs[1].anchors[1].tag, "BinOp")
    test.assert_eq(expression("e @ (lifetime.scope)"), "(e @ (SCOPE))")
    -- An item is any exp, an `@` included.
    test.assert_eq(expression("e @ (a @ b, f())"), "(e @ ((a @ b), f()))")
end)

test.case("`lifetime.scope` followed by a suffix is an ordinary prefixexp", function()
    test.assert_eq(expression("e @ lifetime.scope.x"), "(e @ lifetime.scope.x)")
    test.assert_eq(expression("e @ lifetime.scope()"), "(e @ lifetime.scope())")
    test.assert_eq(expression("e @ lifetime.scope[1]"), "(e @ lifetime.scope[1])")
    test.assert_eq(expression("e @ lifetime.scope:m()"), "(e @ lifetime.scope:m())")
    test.assert_eq(expression("e @ lifetime.scope \"s\""), "(e @ lifetime.scope \"s\")")
    test.assert_eq(expression("e @ lifetime.scope {}"), "(e @ lifetime.scope {})")
    test.assert_eq(expression("e @ lifetime.pin(a)"), "(e @ lifetime.pin(a))")
    test.assert_eq(expression("e @ lifetime.reachable"), "(e @ lifetime.reachable)")
    test.assert_eq(expression("e @ (a, lifetime.scope.x)"), "(e @ (a, lifetime.scope.x))")
    -- Parentheses followed by a suffix start a prefixexp, not a list.
    test.assert_eq(expression("e @ (t).owner"), "(e @ P(t).owner)")
    test.assert_eq(expression("e @ (lifetime.scope).f"), "(e @ P(lifetime.scope).f)")
    test.assert_eq(expression("e @ (get)(1)"), "(e @ P(get)(1))")
    test.assert_eq(parse("x = e @ (lifetime.scope).f")[1].exprs[1].anchors[1].obj.expr.tag, "Member")
    -- Outside anchor position `lifetime.scope` is a field access.
    test.assert_eq(parse("x = lifetime.scope")[1].exprs[1].tag, "Member")
    test.assert_eq(expression("f(lifetime.scope)"), "f(lifetime.scope)")
    test.assert_eq(expression("lifetime.scope @ a"), "(lifetime.scope @ a)")
end)

test.case("`lifetime.scope` is matched by spelling, whatever `lifetime` names", function()
    -- docs/02-semantics.md, "Scopes: `lifetime.scope`": "the transpiler
    -- matches the spelling `lifetime.scope` ... whatever `lifetime` names
    -- at that point".
    local chunk = parse("local lifetime = t; x @ lifetime.scope")
    test.assert_eq(chunk[2].tag, "AnchorStat")
    test.assert_eq(chunk[2].expr.anchors[1].tag, "ScopeAnchor")
    local f = parse("local function f(lifetime) return {} @ lifetime.scope end")[1]
    test.assert_eq(show(f.func.body[1].exprs[1]), "({} @ SCOPE)")
    -- The two Names joined by `.`, across lines too.
    test.assert_eq(expression("e @ lifetime\n.\nscope"), "(e @ SCOPE)")
    -- Other spellings are ordinary prefixexps.
    test.assert_eq(expression("e @ Lifetime.scope"), "(e @ Lifetime.scope)")
    test.assert_eq(expression("e @ lifetime.Scope"), "(e @ lifetime.Scope)")
    test.assert_eq(expression("e @ lifetime[\"scope\"]"), "(e @ lifetime[\"scope\"])")
    test.assert_eq(expression("e @ lt.scope"), "(e @ lt.scope)")
end)

test.case("`scope`, `caller`, `defer` and `token` are ordinary names", function()
    -- docs/04-transpiler.md, "Grammar": "Reserved words: none added".
    test.assert_eq(statement("local scope, caller = 1, 2"), "1, 2")
    test.assert_eq(statement("x @ scope"), "AnchorStat (x @ scope)")
    test.assert_eq(statement("e @ caller"), "AnchorStat (e @ caller)")
    test.assert_eq(statement("e @ lifetime.scope"), "AnchorStat (e @ SCOPE)")
    test.assert_eq(statement("local defer = 1"), "1")
    test.assert_eq(statement("defer(f)"), "CallStat")
    test.assert_eq(statement("local token = 1"), "1")
    test.assert_eq(statement("token = scope + caller"), "(scope + caller)")
    test.assert_eq(statement("local p = lifetime.token(\"p\") @ a"), "(lifetime.token(\"p\") @ a)")
    test.assert_eq(statement("lifetime.token(\"p\") @ a"), "AnchorStat (lifetime.token(\"p\") @ a)")
    test.assert_eq(statement("function scope(caller) return caller end"), "FunctionStat")
end)

test.case("`@` and `!@` are postfix, of the lowest precedence, left-associative", function()
    -- docs/04-transpiler.md, "Grammar": "`@` has the lowest precedence of
    -- any operator and is postfix"; "`!@` has the precedence and the right
    -- operand of `@`".
    test.assert_eq(expression("a + b @ s"), "((a + b) @ s)")
    test.assert_eq(expression("f(x) @ s"), "(f(x) @ s)")
    test.assert_eq(expression("x @ y @ z"), "((x @ y) @ z)")
    test.assert_eq(expression("not x @ a"), "((not x) @ a)")
    test.assert_eq(expression("a .. b or c @ (d, e)"), "(((a .. b) or c) @ (d, e))")
    test.assert_eq(expression("x + y !@ s"), "((x + y) !@ s)")
    test.assert_eq(expression("(f @ a) !@ s"), "(P((f @ a)) !@ s)")
    test.assert_eq(expression("a or b !@ s"), "((a or b) !@ s)")
    test.assert_eq(expression("f !@ a @ b"), "((f !@ a) @ b)")
    test.assert_eq(expression("{f !@ a, x @ b}"), "{(f !@ a), (x @ b)}")
    test.assert_eq(expression("t[x @ a]"), "t[(x @ a)]")
    local node = parse("x = f !@ a @ b")[1].exprs[1]
    test.assert_eq(node.tag, "Anchor")
    test.assert_eq(node.expr.tag, "Hook")
    test.assert_eq(node.expr.expr.name, "f")
    -- An expression that `@` ends is no operand of a binary operator.
    assert_syntax_error("local y = x @ a + 1", "t:1: unexpected symbol near '+'")
    assert_syntax_error("y = x @ a or b", "t:1: unexpected symbol near 'or'")
    assert_syntax_error("f(x @ a .. b)", "t:1: ')' expected near '..'")
end)

test.case("commas: two values with two and one anchor items", function()
    -- docs/02-semantics.md, "Acquiring a lifetime": "`local x, y = {} @
    -- (a, b), {} @ c` is unambiguous".
    local node = parse("local x, y = {} @ (a, b), {} @ c")[1]
    test.assert_eq(#node.exprs, 2)
    test.assert_eq(#node.exprs[1].anchors, 2)
    test.assert_eq(#node.exprs[2].anchors, 1)
    test.assert_eq(show_list(node.exprs), "({} @ (a, b)), ({} @ c)")
    test.assert_eq(expression("f(x @ (a, b), y @ c)"), "f((x @ (a, b)), (y @ c))")
end)

test.case("the statement forms take a prefixexp on the left", function()
    test.assert_eq(statement("x @ a"), "AnchorStat (x @ a)")
    test.assert_eq(statement("x.y[1] @ (a, b)"), "AnchorStat (x.y[1] @ (a, b))")
    test.assert_eq(statement("f() @ a"), "AnchorStat (f() @ a)")
    test.assert_eq(statement("(f) @ a"), "AnchorStat (P(f) @ a)")
    test.assert_eq(statement("obj:m() !@ lifetime.scope"), "HookStat (obj:m() !@ SCOPE)")
    test.assert_eq(statement("obj.close !@ obj"), "HookStat (obj.close !@ obj)")
    test.assert_eq(statement("(a or b) !@ s"), "HookStat (P((a or b)) !@ s)")
    test.assert_eq(statement("x @ a; y @ b", 2), "AnchorStat (y @ b)")
    -- docs/02-semantics.md, "Acquiring a lifetime": "`{} @ lifetime.scope`
    -- on its own is a syntax error"; Lua's words.
    assert_syntax_error("{} @ lifetime.scope", "t:1: unexpected symbol near '{'")
    assert_syntax_error("\"s\" @ a", "t:1: unexpected symbol near '\"s\"'")
    assert_syntax_error("a + b @ s", "t:1: '=' expected near '+'")
end)

test.case("a statement chains `@` and `!@` like an expression", function()
    -- docs/04-transpiler.md, "Grammar": "A statement chains `@` and `!@`
    -- exactly as an expression does, left to right: `f !@ a @ b` as a
    -- statement creates the hook on `a` and moves it to `b`".
    test.assert_eq(statement("x @ a @ b"), "AnchorStat ((x @ a) @ b)")
    test.assert_eq(statement("f !@ a @ b"), "AnchorStat ((f !@ a) @ b)")
    test.assert_eq(statement("x @ a !@ b"), "HookStat ((x @ a) !@ b)")
    test.assert_eq(statement("t.f @ (a, b) @ lifetime.scope @ c"), "AnchorStat (((t.f @ (a, b)) @ SCOPE) @ c)")
    test.assert_eq(statement("function() end !@ a @ b"), "AnchorStat ((function() !@ a) @ b)")
    test.assert_eq(statement("function() end !@ a !@ b"), "HookStat ((function() !@ a) !@ b)")
    local s = parse("f !@ a @ b")[1]
    test.assert_eq(s.expr.tag, "Anchor")
    test.assert_eq(s.expr.expr.tag, "Hook")
    test.assert_eq(s.expr.expr.name, nil)
    -- The expression forms are unchanged, a bound hook still named.
    test.assert_eq(statement("local h = f !@ a @ b"), "((f !@[h] a) @ b)")
    -- The lines of every operator and anchor of a chain over lines.
    s = parse("f\n!@\na\n@\n(\nb\n,\nlifetime.scope\n)")[1]
    test.assert_eq(s.tag, "AnchorStat")
    test.assert_eq(s.line, 1)
    test.assert_deep_eq(s.expr.lines, {4, 5, 7, 9}) -- @ ( , )
    test.assert_deep_eq(s.expr.expr.lines, {2}) -- !@
    test.assert_eq(s.expr.expr.anchors[1].line, 3)
    test.assert_deep_eq(s.expr.anchors[2].lines, {8, 8, 8})
    s = parse("function()\nend\n!@ a\n@ b")[1]
    test.assert_eq(s.tag, "AnchorStat")
    test.assert_deep_eq(s.expr.lines, {4})
    test.assert_deep_eq(s.expr.expr.lines, {3})
    -- What follows a chain is the next statement.
    test.assert_eq(statement("x @ a @ b y = 1", 2), "1")
    assert_syntax_error("x @ a @", "t:1: unexpected symbol near '<eof>'")
    assert_syntax_error("x @ a + b", "t:1: unexpected symbol near '+'")
    assert_syntax_error("function() end @ a !@ b", "t:1: '!@' expected near '@'")
end)

test.case("`function (` starts a statement only with `!@`", function()
    -- docs/04-transpiler.md, "Grammar": "A statement may start with
    -- `function (`, an anonymous function, which must then be followed by
    -- `!@`; `function name` keeps its Lua meaning."
    test.assert_eq(statement("function() print(1) end !@ lifetime.scope"), "HookStat (function() !@ SCOPE)")
    test.assert_eq(statement("function(reason) end !@ (a, b)"), "HookStat (function(reason) !@ (a, b))")
    test.assert_eq(statement("function f() end"), "FunctionStat")
    local node = parse("function(r)\nend !@ s")[1]
    test.assert_eq(node.line, 1)
    test.assert_eq(node.expr.tag, "Hook")
    test.assert_eq(node.expr.expr.tag, "Function")
    test.assert_deep_eq(node.expr.expr.lines, {1, 1, 1, 2}) -- function ( ) end
    assert_syntax_error("function () end", "t:1: '!@' expected near '<eof>'")
    assert_syntax_error("function () end x = 1", "t:1: '!@' expected near 'x'")
    assert_syntax_error("function () end @ a", "t:1: '!@' expected near '@'")
    assert_syntax_error("function () end ()", "t:1: '!@' expected near '('")
    assert_syntax_error("function (a b) end !@ s", "t:1: ')' expected near 'b'")
    assert_syntax_error("function ()\n\n", "t:3: 'end' expected (to close 'function' at line 1) near '<eof>'")
    assert_syntax_error("function ()\n!@ s", "t:2: unexpected symbol near '!@'")
    assert_syntax_error("a or b !@ s", "t:1: '=' expected near 'or'")
end)

test.case("hooks: `!@` with every anchor form, any expression on the left", function()
    test.assert_eq(expression("f !@ a"), "(f !@ a)")
    test.assert_eq(expression("f !@ lifetime.scope"), "(f !@ SCOPE)")
    test.assert_eq(expression("f !@ (a, b)"), "(f !@ (a, b))")
    test.assert_eq(expression("f !@ (a, lifetime.scope)"), "(f !@ (a, SCOPE))")
    test.assert_eq(expression("f !@ lifetime.pin(a)"), "(f !@ lifetime.pin(a))")
    test.assert_eq(statement("local h = function() return 1 end !@ lifetime.scope"), "(function() !@[h] SCOPE)")
    local node = parse("x = f !@ (a, lifetime.scope)")[1].exprs[1]
    test.assert_eq(node.tag, "Hook")
    test.assert_eq(node.anchors[2].tag, "ScopeAnchor")
    -- The runtime rejects what is not a function, the parser does not
    -- (docs/02-semantics.md, "Hooks": "attempt to defer a number value").
    test.assert_eq(expression("5 !@ a"), "(5 !@ a)")
    test.assert_eq(expression("\"s\" !@ a"), "(\"s\" !@ a)")
    -- "The anchor is always written."
    assert_syntax_error("x = f !@", "t:1: unexpected symbol near '<eof>'")
    assert_syntax_error("f !@", "t:1: unexpected symbol near '<eof>'")
    assert_syntax_error("x = f !@ 5", "t:1: unexpected symbol near '5'")
    assert_syntax_error("x = f @ {}", "t:1: unexpected symbol near '{'")
end)

test.case("`@()` is a syntax error, lists do not nest", function()
    assert_syntax_error("x = e @ ()", "t:1: empty anchor list near ')'")
    assert_syntax_error("e @ ( )", "t:1: empty anchor list near ')'")
    assert_syntax_error("f !@ ()", "t:1: empty anchor list near ')'")
    -- A nested list is Lua's parenthesised expression, which holds no
    -- comma: Lua's words for `x = (b, c)` (see the task file, "Spec issues
    -- found").
    assert_syntax_error("x = e @ (a, (b, c))", "t:1: ')' expected near ','")
    assert_syntax_error("x = e @ (a,\n(b,\nc))", "t:2: ')' expected near ','")
    assert_syntax_error("x = e @ (a, b", "t:1: ')' expected near '<eof>'")
    assert_syntax_error("x = e @ (a,\n\nb", "t:3: ')' expected (to close '(' at line 1) near '<eof>'")
    assert_syntax_error("x = e @ (a,)", "t:1: unexpected symbol near ')'")
    -- `lifetime.scope` in a list is the anchor, so nothing may follow it
    -- that does not continue a prefixexp.
    assert_syntax_error("x = e @ (lifetime.scope + 1)", "t:1: ')' expected near '+'")
    -- After a list, a suffix continues nothing.
    assert_syntax_error("x = e @ (a, b).c", "t:1: unexpected symbol near '.'")
end)

test.case("named hooks: `local NAME`, `NAME` and `t.NAME` name the hook, nothing else does", function()
    -- docs/02-semantics.md, "Named hooks".
    test.assert_eq(statement("local h = f !@ x"), "(f !@[h] x)")
    test.assert_eq(statement("h = f !@ x"), "(f !@[h] x)")
    test.assert_eq(statement("t.h = f !@ x"), "(f !@[h] x)")
    test.assert_eq(statement("self.on_close = f !@ self"), "(f !@[on_close] self)")
    test.assert_eq(statement("a.b.c = f !@ x"), "(f !@[c] x)")
    test.assert_eq(statement("t[k] = f !@ x"), "(f !@ x)")
    test.assert_eq(statement("t[\"h\"] = f !@ x"), "(f !@ x)")
    test.assert_eq(show(parse("g(f !@ x)")[1].call.args[1]), "(f !@ x)")
    test.assert_eq(statement("f !@ x"), "HookStat (f !@ x)")
    test.assert_eq(statement("function() end !@ x"), "HookStat (function() !@ x)")
    test.assert_eq(statement("t = {h = f !@ x}"), "{h = (f !@ x)}")
    test.assert_eq(statement("local h = g(f !@ x)"), "g((f !@ x))")
    test.assert_eq(statement("local h = cond and f !@ x"), "((cond and f) !@[h] x)")
    -- Each target names its own value.
    test.assert_eq(statement("local a, b = f !@ x, g !@ y"), "(f !@[a] x), (g !@[b] y)")
    test.assert_eq(statement("a, t[1], t.c = f !@ x, g !@ y, k !@ z"), "(f !@[a] x), (g !@ y), (k !@[c] z)")
    test.assert_eq(statement("local a = f !@ x, g !@ y"), "(f !@[a] x), (g !@ y)")
    test.assert_eq(statement("local a, b = f !@ x"), "(f !@[a] x)")
    -- The value of `e @ a` and of `(e)` is `e`: the hook moved or
    -- parenthesised is still the value bound.
    test.assert_eq(statement("local h = f !@ x @ y"), "((f !@[h] x) @ y)")
    test.assert_eq(statement("local h = (f !@ x)"), "P((f !@[h] x))")
    -- A hook of a hook (a runtime error) names the outer one.
    test.assert_eq(statement("local h = f !@ x !@ y"), "((f !@ x) !@[h] y)")
    -- An `@` with nothing hooked names nothing.
    test.assert_eq(statement("local h = f @ x"), "(f @ x)")
end)

test.case("`!@` is one token; a lone `!` and `!=` are syntax errors", function()
    assert_syntax_error("x = f ! @ a", "t:1: unexpected symbol near '!'")
    assert_syntax_error("f ! @ a", "t:1: '=' expected near '!'")
    assert_syntax_error("x = !a", "t:1: unexpected symbol near '!'")
    -- docs/04-transpiler.md, "Grammar".
    assert_syntax_error("a != b", "t:1: unexpected symbol near '!' (use '~=' for inequality)")
    assert_syntax_error("if a != b then end", "t:1: unexpected symbol near '!' (use '~=' for inequality)")
    assert_syntax_error("x = a ~= b\n\ny = a != b", "t:3: unexpected symbol near '!' (use '~=' for inequality)")
    -- An earlier syntax error is reported first: Lua reports a malformed
    -- token only when the parser reaches it.
    assert_syntax_error("x = = a != b", "t:1: unexpected symbol near '='")
end)

test.case("LuaJIT's `goto` and labels; `goto` is still an ordinary name", function()
    local chunk = parse("goto continue\n::continue::\n:: done ::")
    test.assert_eq(chunk[1].tag, "Goto")
    test.assert_eq(chunk[1].name, "continue")
    test.assert_deep_eq(chunk[1].lines, {1, 1})
    test.assert_eq(chunk[2].tag, "Label")
    test.assert_eq(chunk[2].name, "continue")
    test.assert_deep_eq(chunk[2].lines, {2, 2, 2})
    test.assert_eq(chunk[3].name, "done")
    -- As in LuaJIT, `goto` followed by a Name is a goto, across lines too.
    chunk = parse("for i = 1, 3 do\n  if i == 2 then goto\n  skip end\n  print(i)\n  ::skip::\nend")
    local jump = chunk[1].body[1].blocks[1][1]
    test.assert_eq(jump.tag, "Goto")
    test.assert_deep_eq(jump.lines, {2, 3})
    test.assert_eq(chunk[1].body[3].tag, "Label")
    test.assert_eq(chunk[1].body[3].line, 5)
    -- Everywhere else `goto` is a Name (Lua 5.1 and LuaJIT agree).
    test.assert_eq(statement("local goto = 1"), "1")
    test.assert_eq(statement("goto = 1"), "1")
    test.assert_eq(statement("goto(x)"), "CallStat")
    test.assert_eq(statement("goto.x = 1"), "1")
    test.assert_eq(statement("goto \"s\""), "CallStat")
    test.assert_eq(expression("goto"), "goto")
    assert_syntax_error("goto 1", "t:1: '=' expected near '1'")
    assert_syntax_error("::x", "t:1: '::' expected near '<eof>'")
    assert_syntax_error(":: 1 ::", "t:1: '<name>' expected near '1'")
    assert_syntax_error("x = ::y::", "t:1: unexpected symbol near '::'")
end)

test.case("the extended chunk parses, statement by statement, a line on every node", function()
    local chunk = parse(chunks.EXTENDED)
    local tags, lines = {}, {}
    for i = 1, #chunk do
        tags[i], lines[i] = chunk[i].tag, chunk[i].line
    end
    test.assert_deep_eq(tags, {
        "Local", "Local", "Local", "Local", "Local", "AnchorStat", "HookStat", "HookStat", "Local", "Set", "Local", "Local", "Local", "AnchorStat",
        "Goto", "Label", "Local", "Set", "Local", "Return"
    })
    test.assert_deep_eq(lines, chunks.EXTENDED_STATEMENT_LINES)
    local count = 0
    each_node(chunk, function(node)
        count = count + 1
        test.assert_eq(type(node.line), "number", "line of a " .. node.tag)
        for _, line in ipairs(node.lines or {}) do
            test.assert_eq(type(line), "number", "lines of a " .. node.tag)
        end
    end)
    test.assert_true(count > 100, "the walk saw " .. count .. " nodes")
    test.assert_eq(show_list(chunk[10].exprs), "(f !@[on_close] self), (g !@ self)")
    test.assert_eq(show(chunk[19].exprs[1]), "((function() !@[z] (SCOPE, a)) @ b)")
end)

test.case("the lines of the extension's own tokens", function()
    local chunk = parse(chunks.EXTENDED)
    local anchor = chunk[19].exprs[1]
    test.assert_eq(anchor.tag, "Anchor")
    test.assert_eq(anchor.line, 19)
    test.assert_deep_eq(anchor.lines, {29}) -- @
    test.assert_eq(anchor.anchors[1].line, 30)
    local hook = anchor.expr
    test.assert_eq(hook.line, 19)
    test.assert_deep_eq(hook.lines, {21, 22, 26, 28}) -- !@ ( , )
    test.assert_deep_eq(hook.anchors[1].lines, {23, 24, 25}) -- lifetime . scope
    test.assert_eq(hook.anchors[1].line, 23)
    test.assert_eq(hook.anchors[2].line, 27)
    test.assert_deep_eq(chunk[19].lines, {19, 19}) -- local =
    -- `(t).owner` as an anchor: the parentheses belong to the Paren.
    local moved = chunk[14].expr
    test.assert_deep_eq(moved.lines, {14})
    test.assert_deep_eq(moved.anchors[1].obj.lines, {14, 14})
    test.assert_eq(moved.list, nil)
    test.assert_deep_eq(parse("x = e @\n(\na\n)")[1].exprs[1].lines, {1, 2, 4})
    test.assert_deep_eq(parse("x = e @\n(\na\n)\n.b")[1].exprs[1].lines, {1})
    local member = parse("x = e @\n(\nlifetime\n.\nscope\n)\n.b")[1].exprs[1].anchors[1].obj.expr
    test.assert_deep_eq(member.lines, {4, 5})
    test.assert_eq(member.obj.line, 3)
end)
