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
    end
    error("show: unexpected node " .. tostring(tag))
end

-- The expression `x = <source>` assigns.
local function expression(source)
    local chunk = parse("x = " .. source)
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
    -- The task names `unexpected symbol near '@'` for `x @ y`; Lua 5.1
    -- says that only where `@` starts an expression or a statement. As a
    -- statement, `x` is the start of an assignment and Lua expects `=`
    -- (see the task file, "Spec issues found").
    {"local z = x @ y", "t:1: unexpected symbol near '@'"},
    {"x @ y", "t:1: '=' expected near '@'"},
    {"x = 1 !@ y", "t:1: unexpected symbol near '!'"},
    {"f() !@ x", "t:1: unexpected symbol near '!'"},
    {"f() @ x", "t:1: unexpected symbol near '@'"},
    {"x != y", "t:1: '=' expected near '!'"},
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
    {"goto continue", "t:1: '=' expected near 'continue'"},
    {"x = \0", "t:1: unexpected symbol"},
    {"x = \1", "t:1: unexpected symbol near 'char(1)'"},
    {"x = [[a\nb]] + +", "t:2: unexpected symbol near '+'"},
    -- A malformed token is reported when the parser reaches it, so an
    -- earlier syntax error wins, as in Lua (deferred lexing).
    {"x = = \"abc", "t:1: unexpected symbol near '='"},
    {"x = 1 .. 0x", "t:1: malformed number near '0x'"},
    {"\"abc", "t:1: unfinished string near '<eof>'"}
}

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
