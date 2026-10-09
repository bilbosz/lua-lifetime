-- tests/lib/chunks.lua: Lua 5.1 chunks shared by the transpiler tests.
local chunks = {}

-- Every statement and expression form of the manual's §8, one statement
-- per line from line 1 to line 40 (statement N starts on line N), then
-- one statement spread over lines 41 to 49 with a token on every line.
chunks.EVERY_FORM = table.concat({
    "local a, b, c = 1, 0x1F, 3.5e-2", -- 1  Local with values
    "local function f(x, y, ...) return x, y, ... end", -- 2  LocalFunction, varargs, Return
    "function t.a.b:c(p) return self, p end", -- 3  FunctionStat with a method
    "function g(...) local n = select('#', ...); return n; end", -- 4  `;` after statements
    "a.b[c] = d, e", -- 5  Set: Member and Index targets
    "x, y.z, w[1] = f(1), \"s\", [[long]]", -- 6  multiple targets
    "do local q end", -- 7  Do, Local without values
    "while a do break end", -- 8  While, Break
    "repeat a = a - 1 until a <= 0", -- 9  Repeat
    "if a then b = 1 elseif c then b = 2 elseif d then b = 3 else b = 4 end", -- 10 If
    "if a then end", -- 11
    "for i = 1, 10, 2 do end", -- 12 NumericFor with a step
    "for i = 10, 1 do local j = i end", -- 13 NumericFor
    "for k, v in pairs(t) do print(k, v) end", -- 14 GenericFor
    "for k in next, t, nil do break end", -- 15
    "obj:method(1, 2)", -- 16 Invoke
    "obj.field:method \"str\"", -- 17 string-call sugar on a method
    "obj:method { 1, 2 }", -- 18 table-call sugar on a method
    "print 'hello'", -- 19 string-call sugar
    "print { x = 1, [2] = 3; 4, }", -- 20 table-call sugar, every field form, both separators
    "f()();", -- 21 call of a call
    "(f)(1)", -- 22 parenthesised prefix
    "x = (f())", -- 23 Paren truncating to one value
    "x = function(...) return ... end", -- 24 anonymous vararg function
    "x = function() end", -- 25
    "x = { }", -- 26 empty table
    "x = {1, 2, 3,}", -- 27 trailing separator
    "x = {f()}", -- 28
    "x = f{...}[1].y:z(...)", -- 29 a chain of suffixes
    "x = a or b and c < d .. e + f * -g ^ h", -- 30 every precedence level
    "x = a == b, a ~= b, a < b, a <= b, a > b, a >= b", -- 31 comparisons
    "x = a + b - c * d / e % f ^ g .. h", -- 32 arithmetic
    "x = not a, #t, - - a, - -1", -- 33 unary
    "x = true, false, nil, ...", -- 34 literals, vararg in the main chunk
    "x = 'single' .. \"double\\n\\t\\\\\\\"\" .. [==[ level ]] two ]==]", -- 35 strings
    "x = 1, 1.5, .5, 5., 1e10, 1E-2, 0xff, 0XA", -- 36 numerals
    "local function h() return end", -- 37 bare return
    "local function k() return; end", -- 38
    "local u, v", -- 39
    "x = a.b.c.d", -- 40
    "local s = t", -- 41 one statement over nine lines
    "  .field", -- 42
    "  [", -- 43
    "    key", -- 44
    "  ]", -- 45
    "  :method(", -- 46
    "    1,", -- 47
    "    2", -- 48
    "  )", -- 49
    "return x", -- 50
    ""
}, "\n")

-- The lines of chunks.EVERY_FORM on which a statement starts.
chunks.EVERY_FORM_STATEMENT_LINES = {}
for line = 1, 41 do
    chunks.EVERY_FORM_STATEMENT_LINES[line] = line
end
chunks.EVERY_FORM_STATEMENT_LINES[42] = 50

-- Every form the extension adds (docs/04-transpiler.md, "Grammar") and
-- LuaJIT's `goto` and labels, one statement per line from line 1 to line
-- 18, then one statement spread over lines 19 to 30 with a token on every
-- line. Not loadable Lua: task 005 parses it, task 006 generates code.
chunks.EXTENDED = table.concat({
    "local a = {} @ lifetime.scope", -- 1  Anchor, ScopeAnchor
    "local b = {} @ (a, lifetime.scope)", -- 2  the list form
    "local c = Buffer.new(4096) @ a", -- 3  a call on the left
    "local d = {} @ lifetime.pin(a, b)", -- 4  an ordinary prefixexp anchor
    "local e = {} @ (cond and a or b)", -- 5  a one-element list
    "b @ a", -- 6  AnchorStat
    "obj.close !@ obj", -- 7  HookStat
    "function() print(1) end !@ lifetime.scope", -- 8  HookStat on a function
    "local h = function(reason) end !@ (a, b)", -- 9  a named Hook
    "self.on_close, t[1] = f !@ self, g !@ self", -- 10 named by a Member, not by an Index
    "local p = lifetime.token(\"p\") @ self", -- 11 a token is an ordinary call
    "local x, y = {} @ (a, b), {} @ c", -- 12 commas inside and outside a list
    "local m = f !@ a @ b", -- 13 a hook moved
    "x @ (t).owner", -- 14 parentheses that start a prefixexp
    "goto done", -- 15 LuaJIT
    "::done::", -- 16 LuaJIT
    "local scope, caller, defer, token = 1, 2, 3, 4", -- 17 ordinary names
    "y = x @ lifetime.scope.x", -- 18 lifetime.scope.x is a prefixexp
    "local z = function()", -- 19 one statement over twelve lines
    "end", -- 20
    "  !@", -- 21
    "  (", -- 22
    "    lifetime", -- 23
    "    .", -- 24
    "    scope", -- 25
    "    ,", -- 26
    "    a", -- 27
    "  )", -- 28
    "  @", -- 29
    "  b", -- 30
    "return z", -- 31
    ""
}, "\n")

-- The lines of chunks.EXTENDED on which a statement starts.
chunks.EXTENDED_STATEMENT_LINES = {}
for line = 1, 19 do
    chunks.EXTENDED_STATEMENT_LINES[line] = line
end
chunks.EXTENDED_STATEMENT_LINES[20] = 31

return chunks
