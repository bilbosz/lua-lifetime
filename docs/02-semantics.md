# Semantics of the lifetime extension

This page is the specification of what `lua-lifetime` adds to Lua. It is
derived from the `xd` specification (`xd/docs/02-lifetimes.md`,
`03-destruction.md`, `04-syntax.md`, `06-hooks.md`) with the decisions of
`xd/docs/10-lua-lifetime-decisions.md` ("file 10" below) applied. Each
section names the `xd` section it comes from and the decision that changed
it. Where file 10 leaves something open, this page says "open" and points
at [06-open-questions.md](06-open-questions.md). Anything this page does
not mention behaves as in Lua 5.1, with the Lua 5.1 reference manual as the
citation (`xd/docs/07-decisions.md`, "When the spec is silent, replicate
Lua"; here Lua 5.1 rather than 5.4 by decision 1).

## Host

*From file 10, decision 1.*

The generated code and the runtime run on Lua 5.1 and LuaJIT. Later Lua
versions may work but are not targets. Everything below is shaped by what
these hosts offer: no `<close>`, `goto` only on LuaJIT, `__gc` on userdata
only, no ephemerons, no yield across `pcall` on plain 5.1, finalizers in
reverse creation order, and an object with a pending finalizer staying in
weak tables for one more cycle.

## Vocabulary

*From `xd/docs/02-lifetimes.md`, "Vocabulary"; terms changed by decisions
2, 5, 6, 7, 8 and 11.*

- **Value**: numbers, booleans, strings, `nil`. No lifetime.
- **Object**: tables, functions, coroutines, userdata. Only objects have
  lifetimes. Only tables and tokens can be **anchors** (below), since an
  anchor keeps its dependents inside itself (decision 3) and Lua 5.1 gives
  only tables a place to keep them; see
  [06-open-questions.md](06-open-questions.md), "Non-table anchors".
- **Anchor**: what an object's lifetime refers to. One of: a live table or
  token, the current block (`lifetime.scope`), the term `reachable`
  (`lifetime.reachable`), or a **lifetime value** obtained from
  `lifetime.of(x)` or `lifetime.pin(…)`.
- **Scope**: the activation of a lexical block (`do … end`, a function
  body, a loop body, a `then`/`else` arm). It begins when control enters
  the block and ends when control leaves it by any route: fall-through,
  `break`, `return`, `goto` (LuaJIT) or an error. `lifetime.scope` is
  syntax, not a value (decision 5): it is the anchor spelling the
  transpiler resolves to the block, and it cannot be stored or passed on.
  There is no anchor for the caller's block ("Scopes: `lifetime.scope`").
- **Lifetime formula**: a conjunction of anchors. An object is alive
  while every anchor in its formula is alive and, if the formula has the
  `reachable` term, while something refers to the object. There is no
  disjunction (decision 7). Every object has a
  formula; the default is `reachable`; a formula is **replaced** by
  writing `@` again.
- **`reachable`**: the term that stands for "something still refers to
  this object". Its truth is decided by the host collector (decision 2),
  not at a statement boundary.
- **Token**: an opaque object created by `lifetime.token([name])`
  (decision 6): identity, a dependents list, a hook list, no fields.
- **Dependent**: an object whose formula mentions a given anchor.
- **Hook**: an object created with the operator `!@` whose destructor is
  a user function.
- **Dying**: an object whose death has been decided in the cascade now
  running and whose destructor has not yet run, or has run but whose
  dependents are still being destroyed. Fully usable; cannot be moved or
  anchored to.
- **Dead**: an object whose cascade has finished. A dead table is a
  **tombstone** (decision 8): emptied, with a metatable that raises. A
  dead object is not `nil`; references to it stay where they are.

## The one rule

*From `xd/docs/02-lifetimes.md`, "The one rule"; reachability timing by
decision 2, conjunction only by decision 7.*

> An object is alive if and only if every anchor in its formula is alive,
> where an anchor counts as false once it is dead or dying, and, if the
> formula has the `reachable` term, nothing has yet found the object
> unreachable. The default formula is `reachable`. A formula is
> re-evaluated whenever one of its anchors dies.

Anchors keep their dependents alive only if the formula has no
`reachable` term (a *pinned* object, "The implicit `reachable` term"
below); otherwise the collector may take an unreferenced dependent first.
Anchors kill their dependents: the instant `conn` dies, `buf @ conn` dies,
whoever still refers to `buf`.

Formulas are monotone: anchors only go from alive to dead, and `reachable`
only from true to false, so an object dies at most once and never comes
back (`xd/docs/02-lifetimes.md`, "Why only `all` and `any`"; with only
conjunction left the argument is simpler).

## Acquiring a lifetime: the `@` operator

*From `xd/docs/02-lifetimes.md`, "Acquiring a lifetime"; `xd/docs/04-syntax.md`,
"The anchor operator `@`"; list form by decision 11; implicit term by
decision 4.*

```lua
local conn   = Connection.open(sock) @ lifetime.scope             -- the block
local buf    = Buffer.new(4096)      @ conn              -- an object
local header = Slice.new(buf, 0, 64) @ (buf, conn)       -- a conjunction
local entry  = { v = 1 }             @ session           -- dies with the session, or earlier if dropped
local shown  = Screen.new()          @ lifetime.pin(owner)  -- dies with owner, referenced or not
local f      = function() return buf:read() end @ conn
local plain  = {}                                        -- same as `{} @ lifetime.reachable`
```

Grammar (`xd/docs/04-syntax.md` as changed by decision 11):

```ebnf
exp    ::= … | exp '@' anchor
stat   ::= … | prefixexp '@' anchor { '@' anchor }
anchor ::= scopeanchor | prefixexp | '(' anchorlist ')'
anchorlist ::= anchoritem { ',' anchoritem }
anchoritem ::= scopeanchor | exp
scopeanchor ::= 'lifetime' '.' 'scope'
```

`@` is a postfix operator with the lowest precedence of any operator:
`a + b @ s` is `(a + b) @ s`. Its right operand is `lifetime.scope`, a
`prefixexp`, or a parenthesised list. `lifetime.scope` is matched by
spelling, the Names `lifetime` and `scope` joined by `.`, before the
`prefixexp` alternative ("Scopes: `lifetime.scope`"). A one-element list is the plain form:
`x @ (a)` is `x @ a`, so Lua's own parenthesised expression after `@`,
`x @ (cond and a or b)`, keeps working. An empty list `@()` is a syntax
error. Lists do not nest. In an expression list the commas of a conjunction
are inside its parentheses, so `local x, y = {} @ (a, b), {} @ c` is
unambiguous.

Semantics of `e @ a1, …, an`:

1. Evaluate `e`. The result must be an object (`attempt to anchor a number
   value`).
2. Evaluate each element left to right. Each must be a live table or
   token, `lifetime.scope`, `lifetime.reachable`, or a lifetime value. A
   dead or dying object, `nil`, a value, or a function, coroutine or
   userdata (not an anchor, see "Vocabulary") is an error: `attempt to
   anchor to a nil value`, `attempt to anchor to a dying table`, `attempt
   to anchor to a dead table`.
3. If `e` is dying, error: `attempt to move a dying table`. If `e` is dead,
   the dead metatable raises first (see "Tombstones").
4. The conjunction of the elements, with the implicit `reachable` term
   added by the rule below, **replaces** the object's formula. The
   expression yields the object. The object leaves the dependent lists of
   its old anchors and joins those of its new ones, at the end of each
   list. Its own dependents are untouched: they move with it.

The statement form `obj @ anchor` is a **move** (`xd/docs/02-lifetimes.md`,
"Changing a lifetime: moves"): only the formula changes; identity,
contents, metatable and references stay; dependents travel with the
object; every new anchor must be alive; `obj @ lifetime.reachable`
releases the object to the collector; last writer wins, and there is no
way to freeze a lifetime. The left side must be a `prefixexp`, so
`{} @ lifetime.scope` on its own is a syntax error.

**No moves during destruction** (`xd/docs/03-destruction.md`, rule 4;
`xd/docs/07-decisions.md`, "Objects created during a destroy phase may be
moved"): while a cascade's destroy phase is running, `@` may be applied
only to objects on the default formula and to objects created during that
same destroy phase. Moving an older, explicitly anchored object, the dying
object included, is `attempt to move an anchored table during destruction`.
"That same destroy phase" is the innermost one running where the `@`
executes; one phase is one `lifetime.destroy()` or `lifetime.discard()` call, one scope exit
with dependents, one finalizer run, or the program-end sweep.

Constructors return objects on the default lifetime and leave anchoring to
the caller, which is where it belongs.

## The implicit `reachable` term and `lifetime.pin`

*From file 10, decision 4; the combination with the list form is this
repository's decision ([05-decisions.md](05-decisions.md), "`lifetime.pin`
takes the list").*

`x @ a` means `x @ (a, lifetime.reachable)`: `x` dies with `a` at the
latest, or earlier when nothing refers to it. The same holds for `@ lifetime.scope`,
`@ tok` and for a list: `x @ (a, b)` is `x @ (a, b,
lifetime.reachable)`. Two exceptions:

- `f !@ a` keeps replace semantics: a hook is pinned by its anchor,
  because nothing else refers to a hook and a collectable hook would never
  run.
- `lifetime.pin(a1, …, an)` returns a lifetime value over the listed
  anchors **without** the term: `x @ lifetime.pin(a)` is "alive while `a`
  is, referenced or not". It exists for the rare case of an object that
  must survive while unreferenced, such as a hidden screen reused later
  (lesson 6 of `xd/docs/09-lessons-from-treflove.md`).

Precisely: the formula of a list carries the `reachable` term if any
element is a table, token, `lifetime.scope`, `lifetime.reachable`, or a
lifetime value that carries it. `lifetime.pin` strips the term from its
arguments. `lifetime.pin()` with no arguments, and `lifetime.pin` of
nothing but `lifetime.reachable`, are errors (`bad argument #1 to
'lifetime.pin' (anchor expected, got no value)` and `attempt to pin an empty
lifetime`): an empty conjunction would be `forever`, which
`xd/docs/07-decisions.md`, "No `forever`" rejected.

One consequence (decision 4): `local tmp = {} @ lifetime.scope` followed by
`tmp = nil` mid-block no longer destroys `tmp` at scope exit; the collector
takes it whenever it runs. Every other scope use is unchanged, since the
local keeps the object referenced until the block ends.

## Scopes: `lifetime.scope`

*From `xd/docs/02-lifetimes.md`, "Scopes as anchors"; the scope functions
of `xd` replaced by syntax through decision 5. `xd`'s "The caller's scope"
(`caller`, the scope at level 2) is not part of this language
([05-decisions.md](05-decisions.md), "`caller` is removed").*

`lifetime.scope` after `@` is the innermost block enclosing the `@`.

- An object anchored to `lifetime.scope` dies when the block exits by any
  route. The transpiler emits an epilogue on every ordinary exit path
  (fall-through, `return`, `break`, `goto`;
  [04-transpiler.md](04-transpiler.md)). On the error path the runtime
  unwinds at the **raise point**: the scopes of every block between the
  raise and the `pcall`, `xpcall`, `coroutine.resume` or `coroutine.wrap`
  that catches the error die innermost first, each in its own reverse
  attachment order, while the frames that raised are still on the stack
  and before that call returns to its caller
  ([05-decisions.md](05-decisions.md), "Scopes unwind at the raise
  point"). The locals of those frames are alive while the scopes unwind,
  so a dependent of an unwound scope is reachable until its own
  destructor runs and the collector cannot take it first. An `xpcall`
  message handler runs first, at the same point, before any of them, as
  in Lua; what it returns is the error value the call returns, and a
  handler that raises gives Lua's `error in error handling` with the
  scopes unwound all the same. The runtime's handler stands between the
  user's `h` and the raise, so a traceback taken by `h` (`xpcall(f,
  debug.traceback)`) shows the runtime's two frames above the raising
  one; `lifetime run` hides them from its own report. One host limit:
  on Lua 5.1 the host's `xpcall` passes no arguments, and a C function
  or a callable that is not a Lua function cannot be carried to it
  without changing the position in its error messages, so `pcall(f,
  a, ...)` with such an `f` unwinds when the original `pcall` returns,
  as before this rule. A record pushed by a Lua callback of such a call
  (`pcall(require, name)`, `pcall(table.sort, t, cmp)`, `pcall(string.
  gsub, s, p, fn)`, `pcall(tostring, obj)` with a `__tostring`,
  `pcall(callable_table, ...)`) is unwound in the same order, but its
  dependents are reachable only while something else refers to them.
  `pcall(f)` with no argument and every Lua function are exact on both
  hosts; LuaJIT has no such limit ([05-decisions.md](05-decisions.md),
  "Scopes unwind at the raise point", host limits). For this the
  runtime replaces those four
  functions in the global environment when it is first required; a
  program must require `lifetime` before any code captures them into a
  local, and `lifetime run` does. A record
  that a catch the runtime could not see left behind dies at the next
  scope exit of the same coroutine that finds it above itself, innermost
  first, or at program end; that is the one observable difference from
  unwinding at the block, and it is the error-path cost of a capture the
  runtime did not see, not of a block. One error keeps no order: a stack
  overflow. The host runs the unwinding with little stack; a destructor
  that overflows again is caught like any destructor error during
  unwinding ("Errors in destructors and `destroyerror`") and the
  unwinding goes on, but when the unwinding itself overflows the host
  ends it and the protected call returns `false` with the host's message
  (`error in error handling` on Lua 5.1, `stack overflow` on LuaJIT);
  the records it did not reach die by the rule for a catch the runtime
  could not see.
- Each entry into a block is a new scope. A loop body gets a fresh scope
  every iteration, so `{} @ lifetime.scope` in a loop body dies at the end of that
  iteration. A function body is a scope; its parameters live in it. The
  main chunk's scope ends when the chunk finishes ("Program end").
- `lifetime.scope` is syntax, not a value ([05-decisions.md](05-decisions.md),
  "The scope anchor is spelled `lifetime.scope`"). In anchor position,
  after `@` or `!@` or as an item of the list form, the transpiler
  matches the spelling `lifetime.scope` (the Names `lifetime` and `scope`
  joined by `.`, whatever `lifetime` names at that point) and resolves it
  to the enclosing block: no scope exists at run time for a block that
  does not anchor to it, and no bookkeeping runs per call. Only the
  block that writes `@ lifetime.scope` or `!@ lifetime.scope` pays
  ([03-runtime.md](03-runtime.md), "Performance"). `scope` on its own is
  an ordinary name; the extension adds no reserved word.
- Anywhere else `lifetime.scope` is an ordinary expression and reads the
  field `scope` of the runtime table, a marker with no other use: `@` on
  it raises `attempt to anchor to lifetime.scope through a variable`
  (as does `!@`, and the marker as the left operand of either), indexing,
  assigning or calling it raises `attempt to index lifetime.scope`,
  `tostring` renders `lifetime.scope`, `getmetatable` gives the string
  `"lifetime.scope"`, and `lifetime.destroy`, `lifetime.discard`, `lifetime.of` and
  `lifetime.format` refuse it with their argument error (`object expected,
  got lifetime.scope`). So a scope cannot be stored, returned,
  compared or passed as an argument. There is therefore no dead scope
  token and no loop-iteration trap: a scope is named only from inside
  itself.
- `lifetime.destroy` of a scope is impossible; scopes end when their block exits.
- There is no anchor for the calling function's block. A function cannot
  name its caller's scope; it returns the object on the default lifetime
  and the receiver anchors it where it wants it, as constructors do
  ("Acquiring a lifetime"):

  ```lua
  local function open_log(path)
    return Log.open(path)             -- default lifetime: the receiver decides
  end

  local log = open_log("app.log") @ lifetime.scope   -- dies when this block exits
  ```

Returning an object anchored to `lifetime.scope` alone hands the caller a
tombstone
(`xd/docs/02-lifetimes.md`, "Returning a scope-anchored object", with the
tombstone of decision 8 in place of `nil`). Return it unanchored, as
above, or anchor it to what the caller passed in.

## Tokens: `lifetime.token`

*From file 10, decision 6. Created by a function of the `lifetime` module
at the human's request ([05-decisions.md](05-decisions.md), "Tokens are
created by `lifetime.token`"), not by the declaration form decision 6
names.*

A token names a span of time: "logged in", "this view's generation", "the
current script". `lifetime.token([name])` returns a fresh one, on the
default lifetime like any new object, and `@` gives it a lifetime:

```lua
function Session:login(user)
  local period = lifetime.token("period") @ self   -- ends at logout, or with the session
  self.period = period
  self.menu = Screen.new("menu") @ period
  backstack:push(function() self:logout() end) @ period
end

function Session:logout()
  lifetime.destroy(self.period)             -- the entry, then the menu, in reverse order of attachment
end
```

- `name` is an optional string used only for display: `tostring(tok)` is
  `token NAME`, or `token: 0x…` without a name, and `lifetime.format` and
  the tombstone's message use the same text. A name that is not a string
  is `bad argument #1 to 'lifetime.token' (string expected, got number)`.
- A token is an object for every rule on this page: it is an anchor
  (`menu @ period`), a dependent (`lifetime.token() @ self`), it can be
  moved, destroyed and discarded, and `lifetime.dependents(period)` lists
  what it owns.
- Like any object anchored with `@`, `lifetime.token("period") @ self`
  carries the implicit `reachable` term: it dies with `self`, or earlier
  if nothing refers to it. Keep it in a field, as above, or pin it:
  `lifetime.token("period") @ lifetime.pin(self)`.
- It has no fields: indexing or assigning a field raises `attempt to index
  a token value`. `getmetatable(tok)` is the string `"token"`. A token has
  no `__destroy`; attach a hook for cleanup that belongs to the span
  itself.

## Hooks: the `!@` operator

*From `xd/docs/06-hooks.md` and `xd/docs/04-syntax.md`, "`defer`",
respelled as an infix operator at the human's request
([05-decisions.md](05-decisions.md), "Hooks are made with the operator
`!@`"); named hooks are this repository's ("A hook bound to a name
carries the name"); the order relative to `__destroy` by decision 10;
pinning by decision 4.*

```ebnf
exp  ::= … | exp '!@' anchor
stat ::= … | prefixexp '!@' anchor | functiondef '!@' anchor
```

`f !@ a` turns the function `f` into a **hook** attached to `a`: an
object whose death calls `f`. It is `xd`'s `defer f @ a` written as one
operator: `@` attaches an object to a lifetime, `!@` attaches an action.

```lua
local hook = function() print("exited") end !@ lifetime.scope   -- runs when this block exits
function() cache[key] = nil end !@ session             -- runs when session dies
unsubscribe !@ (emitter, listener)                     -- runs when either dies
```

- `!@` is a postfix operator with the precedence and the right operand of
  `@`: the lowest precedence of any operator, and `lifetime.scope`, a
  `prefixexp` or a parenthesised list on the right. It applies to the whole
  expression on its left, so `a or b !@ s` hooks the value of `a or b`.
  `@` and `!@` associate to the left: `f !@ a @ b` creates the hook on `a`
  and then moves it to `b`.
- The left operand must be a function: `attempt to defer a number value`.
  A hook is not a function, so `h !@ x` on a hook is `attempt to defer a
  hook value`; a hook is moved with `@`.
- **The anchor is always written.** There is no bare form and no default
  lifetime: cleanup at block exit is `f !@ lifetime.scope`, which says what `xd`'s
  bare `defer f` said by default. `f !@ lifetime.reachable` keeps no
  reference, so the collector may run `f` at any later time; legal and
  almost never meant.
- As a statement the left side is a `prefixexp` or an anonymous `function
  … end`, so `function() … end !@ lifetime.scope` stands on its own; any other
  expression needs parentheses at statement start, as for `@`.
- `!@` is one token: `!` immediately followed by `@`. A lone `!` is a
  syntax error, and `a != b` reads `unexpected symbol near '!' (use '~='
  for inequality)`.
- A hook is a dependent of its anchors, so it runs exactly where an object
  anchored to the same formula would be destroyed, and it is always pinned
  ("The implicit `reachable` term"), whether or not anything holds it. A
  move keeps it pinned: `hook @ other` never adds the `reachable` term to
  a hook.
- The function is called as `fn(reason)` with the reason of
  "`__destroy` and reasons". Whether it also learns which anchor died is
  open (proposal D of `xd/docs/09-lessons-from-treflove.md`;
  [06-open-questions.md](06-open-questions.md)).
- A hook on an object runs **after** that object's `__destroy`, interleaved
  with the object's other dependents by attachment order, most recently
  attached first (decision 10, reversing the sentence in
  `xd/docs/06-hooks.md`). Among hooks on one scope this is still
  last-deferred-first-run.
- A hook is a table with the private metatable `"hook"`: `getmetatable(h)
  == "hook"`; calling or indexing it raises `attempt to call a hook value`
  / `attempt to index a hook value`.

```lua
do
  local f = io.open(path) @ lifetime.scope
  function() print("after f is still open") end !@ lifetime.scope
  local g = io.open(other) @ lifetime.scope
  function() print("runs first") end !@ lifetime.scope
end
-- order: "runs first", g destroyed, "after f is still open", f destroyed
```

### Named hooks

A hook is an object, so the expression form hands it back, and holding it
is how a hook is run early, cancelled or moved:

```lua
local hook = fn !@ self
lifetime.destroy(hook)       -- runs fn now with reason "destroy"; hook is dead afterwards
lifetime.destroy(hook)       -- no-op: a dead hook does nothing
-- instead: lifetime.discard(hook)  cancels it, fn never runs
-- instead: hook @ other   re-targets it, fn runs when other dies
```

- A hook created as the value bound to a name carries that name: `local
  NAME = f !@ …`, `NAME = f !@ …` and `t.NAME = f !@ …` (so `self.NAME =
  f !@ …`) name the hook `NAME`; in a multiple assignment each hook takes
  the name of its own target. `tostring(hook)` is `hook NAME`,
  `lifetime.format` renders it as `hook NAME`, and the tombstone's message
  names it. A hook bound any other way (`t[k] = f !@ a`, an argument, a
  statement on its own) is anonymous and `tostring` gives `hook: 0x…`.
- The name is fixed at creation: storing the hook somewhere else later
  does not rename it.
- Holding a handle does not lengthen the hook's life; dropping it does not
  shorten it. A hook dies by its anchors, by `lifetime.destroy`, or by `lifetime.discard`.
- After it runs the hook is dead: a hook runs at most once.
  `lifetime.alive(hook)` is then `false`, `lifetime.destroy` and `lifetime.discard` on it are
  no-ops, and `hook @ other` raises the dead-object error. `lifetime.discard` on a
  live hook cancels it.

Errors raised by the function follow the destructor error rule below.

## Explicit destruction: `destroy` and `discard`

*From `xd/docs/02-lifetimes.md`, "Explicit destruction"; `xd/docs/04-syntax.md`,
"Built-in functions"; no-op rules by decision 10.*

- `lifetime.destroy(obj)` ends `obj`'s lifetime now, whatever its formula, with
  the full cascade. It works on any object the runtime can see, including
  one on the default lifetime. `lifetime.destroy(nil)` is a no-op. `lifetime.destroy` on a
  dead object, or on one whose own destruction has begun (its body has
  started or it is being tombstoned), is a no-op. On a dependent that the
  decide phase has marked dying but the destroy phase has not reached
  yet, `lifetime.destroy` runs it now, as a cascade of its own: a destructor body
  may therefore destroy its own dependents by hand, early and in the
  order it chooses, and the runtime's later pass skips them (C++ makes
  the double delete undefined; the no-op is the safe reading;
  [05-decisions.md](05-decisions.md), "`lifetime.destroy` by hand inside a
  destructor").
  `lifetime.destroy(5)` is `bad argument #1 to 'destroy' (object expected, got
  number)`. `destroy` and `discard` are not builtins and not bound by
  the transpiler: they are fields of the `lifetime` table like `of` and
  `alive`, and a program's own global `destroy` is its own
  ([05-decisions.md](05-decisions.md), "`destroy` and `discard` are
  spelled `lifetime.destroy` and `lifetime.discard`").
- `lifetime.discard(obj)` does the same but skips `obj`'s own destructor (its
  `__destroy`, or for a hook its function). Dependents are still destroyed
  normally. On a hook this is "cancel".
- Destroying an object does not affect its anchors.

How these two reach user code: see [04-transpiler.md](04-transpiler.md),
"The generated chunk header".

## Cascading death: the order of decision 10

*From `xd/docs/02-lifetimes.md`, "Cascading death"; step 2 reversed by
decision 10.*

Death cascades along anchor edges in two phases: **decide**, then
**destroy**. No destructor runs until every death in the cascade has been
decided. When an anchor `A` dies:

1. **Decide.** Mark `A` dying. Every dependent of `A` whose formula is now
   false (every dying object counts as false) is marked dying, and the step
   repeats for its dependents until nothing changes. The dying set is then
   closed: nothing a destructor does can add to it or remove from it. With
   conjunction only, every dependent of a dying anchor dies.
2. **Destroy.** For each dying object, in C++ order:
   1. its own destructor body runs (`__destroy`, or a hook's function),
      with every dependent still alive and usable;
   2. its dependents and hooks are destroyed, **most recently attached
      first**, each recursively by this same rule; a dependent already
      destroyed through another anchor is skipped, so every object is
      destroyed once, in the position given by the first anchor that
      reached it;
   3. it is emptied and tombstoned.

A scope has no body: scope exit destroys the objects anchored to it in
reverse attachment order, like locals in C++. `lifetime.destroy(A)` is the same
walk with `A` as the root and reason `"destroy"` for `A`.

```lua
do
  local a = {} @ lifetime.scope
  local b = {} @ a
  local c = {} @ lifetime.scope
  local d = {} @ (a, c)
  function() print("hook on a") end !@ a
end
```

At the block exit the scope's dependents are `a` then `c`, so reverse
attachment order destroys `c` first: `c`'s body, then `c`'s dependents
(`d`: body, no dependents, tombstone), then `c`'s tombstone. Then `a`: body,
then its dependents newest first: the hook (runs `"hook on a"`), `d`
(already dead, skipped), `b` (body, tombstone), then `a`'s tombstone. The
destructor bodies run in the order `c, d, a, hook, b`.

Why decide first (`xd/docs/02-lifetimes.md`): lifetimes are mutable, and
if destructors ran while deaths were still being decided, a destructor
could move a sibling onto a longer anchor and rescue it. With
decide-then-destroy a dying object is frozen: `@` on it is an error, and
the only question left is order.

**What a destructor may assume** (decision 10, replacing "What a
destructor may assume" in `xd/docs/02-lifetimes.md`): my dependents are
still here and die right after me. A body that logs through the connection
it owns, flushes the buffer it owns, or tells its children to detach can do
so. It may also see dependents it destroyed by hand already torn down;
that is the author's choice, as in C++.

## `__destroy` and reasons

*From `xd/docs/03-destruction.md`, "The `__destroy` metamethod", rules 1
to 4 and 6; signature by decision 10.*

```lua
function Connection.__destroy(self, reason)
  self.socket:shutdown()
  log("closed connection to " .. self.peer .. " (" .. reason .. ")")
end
```

1. `__destroy` is looked up on the object's metatable at the moment of
   death. For functions, coroutines and userdata that means the shared
   per-type metatable read by `debug.getmetatable`, as in Lua.
2. During the call `self` is fully functional: fields, metatable and
   methods work, every dependent is alive, everything it merely references
   is alive unless it is dying in the same cascade.
3. When the cascade reaches step 2.3 the object is dead no matter what the
   method did. There is no resurrection.
4. `__destroy` may create new objects and anchor them to anything alive. It
   may not anchor to `self`, to any other dying object, or move anything
   that predates the destroy phase ("No moves during destruction").
5. `reason` is `"anchor"` when an anchor's death made the formula false
   (a scope exit included), `"destroy"` for `lifetime.destroy(obj)`,
   `"unreachable"` when the collector found the object, and `"exit"` for
   the program-end sweep. There is no third argument: `remaining` is gone
   with the `any` combinator (decision 10). What, if anything, takes its
   place
   is open ([06-open-questions.md](06-open-questions.md)).
6. Base-class destructors: open. File 10 leans towards walking the
   `__index` chain of metatables and calling every distinct `__destroy`
   most-derived first; a merged-index class library must chain its own.
7. Which objects the runtime can notify: those it has seen. An object is
   seen once it has been anchored with `@` (`@ lifetime.reachable`
   included), used as an anchor, given a hook, created by `lifetime.token`,
   or passed to `lifetime.destroy`, `lifetime.discard` or `lifetime.of`. A plain Lua table with a `__destroy` that
   the runtime never saw is collected silently, as Lua collects it; `x @
   lifetime.reachable` is the way to register an object on the default
   lifetime so that its destructor runs when the collector finds it. This
   follows from decision 2 (the host owns the heap) and was confirmed by
   the human ([05-decisions.md](05-decisions.md), "Registration is
   `x @ lifetime.reachable`").

## Tombstones and `lifetime.alive`

*From file 10, decision 8, replacing "Death and references" in
`xd/docs/03-destruction.md`. Raising rather than reading `nil` is this
repository's decision ([05-decisions.md](05-decisions.md), "The dead
metatable raises").*

When a table dies by cascade, scope exit or `lifetime.destroy`, the runtime empties
it (every field, including the array part) and gives it the **dead
metatable**. References to it stay where they are: in locals, upvalues,
fields, keys of weak and strong tables. Identity is kept: two different
dead objects are still different, and `t[dead]` still finds the entry.

- Indexing, assigning a field, calling, and every other metamethod-driven
  operation on a tombstone raises
  `attempt to index a dead table (<name>, died at <where>, <reason>)`,
  with `index`, `assign to` or `call` as the verb. `<name>` is
  `tostring(obj)` as it read just before the object died, so a
  `__tostring` gives it a name; `<where>` is the source position of the
  statement that caused the cascade (the `lifetime.destroy` call, the block exit,
  or `collector` for a death the collector found); `<reason>` is the reason
  of "`__destroy` and reasons".
- `rawget`, `rawset`, `next`, `pairs`, `#` and `==` do not raise: they see
  a table that holds nothing but the reduced state record under the
  private key (`next(dead)` returns that key; `lifetime.is_state(k)`
  skips it; `#dead` is 0), as every table the runtime has seen does
  ([05-decisions.md](05-decisions.md), "A tombstone keeps its state
  record"). `tostring(dead)` is `dead <name>`. `getmetatable(dead)`
  is the string `"dead"`; `setmetatable` on it raises Lua's "cannot change
  a protected metatable".
- `lifetime.alive(x)` is the liveness check that replaces `if x then`:
  `true` for an object that is alive or dying, `false` for a tombstone and
  for `nil` or `false`; a value that is not an object is `bad argument #1
  to 'lifetime.alive' (object expected, got number)`.
  A lifetime value and the `lifetime.scope` marker are tables the
  runtime made and never kills, so `alive` is `true` for them.
- A dead function, coroutine or userdata cannot be emptied or given a
  per-instance metatable. The runtime remembers that it died so that
  `lifetime.alive` reads `false`, `lifetime.destroy` and `lifetime.discard` are no-ops, and
  `@` raises `attempt to move a dead function (<name>, died at <where>,
  <reason>)` (with `thread` or `userdata` for the other two);
  `lifetime.of` and `lifetime.format` raise the same with `index`. Using
  it otherwise (a call, a resume, a userdata method) is not caught and
  behaves as in Lua. The dying and destruction errors use the same type
  names: `attempt to move a dying function`, `attempt to move an anchored
  function during destruction` ([05-decisions.md](05-decisions.md),
  "Non-table dependents: remembered after death, weak anchors").
- Objects that die by `reachable` need no tombstone: by definition nothing
  refers to them.

A **dying** object is not dead: fields, methods and metamethods behave as
for a live object, which is what lets a hook on `conn` still talk to
`conn` and a dependent's destructor still read its anchor. Only `@` on it
and anchoring to it are refused.

Weak tables keep their Lua meaning: a weak entry is cleared when its key or
value is collected, which for a tombstone is once nothing else refers to it
(5.1 clears weak entries one cycle after the finalizer, "Host"). An object
still held in an array stays as a tombstone until something removes it by
identity, usually a hook that runs while the object is dying and still
findable.

## Errors in destructors and `destroyerror`

*From `xd/docs/03-destruction.md`, rule 5 and "`destroyerror`"; kept by
decision 10.*

Errors raised inside `__destroy` and inside hook functions follow the C++
rule, whatever caused the death:

- If no error is already propagating, the **first** error of the cascade is
  held until the rest of the cascade has finished and then propagates to
  the statement that caused the death: the `lifetime.destroy` call, or the block
  exit (`return`, `break`, `goto`, or a loop iteration included). From
  then on it counts as propagating for the rest of its cascade.
- Every error raised while an error is already propagating (a later
  destructor of the same cascade, or any destructor running because a
  scope is unwinding) goes to `destroyerror` and the original error
  continues.
- One cascade is one `lifetime.destroy()` or `lifetime.discard()` call, one scope exit, one
  finalizer run, or the whole program-end sweep; a `lifetime.destroy()` inside a
  destructor is a cascade of its own and raises to that call.
- A destructor run by the collector (reason `"unreachable"`, or `"exit"`
  at program end) has no statement to raise at: the sentinel's finalizer
  runs the cascade in protected mode and every error of it goes to
  `destroyerror`, the first included ([05-decisions.md](05-decisions.md),
  "Errors in finalizer-run destructors go to `destroyerror`").

`destroyerror(obj, err)` is a global function, looked up raw in `_G` at the
moment an error is routed, called with the dying object (still usable) and
the error value. The default writes `destroyerror: <message>` and a
traceback to `stderr`. Programs may replace it. If the handler itself
raises, or the global is not callable, the runtime writes both errors to
`stderr` (the second as `destroyerror: error in destroyerror (<message>)`)
and continues.

## Reachability is the collector's

*From file 10, decision 2, replacing "`reachable` is exact" in
`xd/docs/02-lifetimes.md` and "The collector" in `xd/docs/03-destruction.md`.*

An object whose formula has the `reachable` term, and that nothing refers
to any more, dies when Lua's collector finds it. Nothing is promised about
when that is, except:

- **`collectgarbage("collect")` is the deterministic point.** When it
  returns, every object that was unreachable before the call has had its
  cascade run, with reason `"unreachable"`. Weak entries that held such an
  object clear one collection later ("Host"), so a test that checks a
  weak table collects twice. The call is a statement of its own, in the
  frame that dropped the reference: a stack slot of a call still being
  built counts as a reference on both hosts, so `print(pcall(function()
  g = nil; collectgarbage("collect") end))` need not collect `g` under
  LuaJIT, while `g = nil` followed by `collectgarbage("collect")` on its
  own line does (task 008).
- Within one collection, objects are finalized **newest first** by
  creation ("Host"), each taking its whole subtree in cascade order; an
  object already destroyed in an earlier walk is skipped. This is the
  order `xd/docs/03-destruction.md`, "A cycle", step 4 gives. A
  consequence the host forces: when a whole subtree is collected at once,
  a dependent that needs a sentinel of its own (it has a `__destroy`,
  dependents or hooks) was armed after its anchor and so dies first, with
  reason `"unreachable"`, before its anchor's own cascade, which then
  skips it; only a dependent without a sentinel dies through its anchor
  with `"anchor"`. Ownership order holds for every death the program
  causes; the collector's deaths follow its order.
- A destructor run by the collector runs at an arbitrary allocation point,
  in the middle of whatever the program was doing. Deterministic ownership
  does not remove reentrancy; code that dispatches events keeps its
  lock-and-defer machinery (lesson 5 of `xd/docs/09-lessons-from-treflove.md`).
- Reachability follows ordinary references only. The runtime's own edges
  from an anchor to its dependents are weak and do not count
  ([03-runtime.md](03-runtime.md)); a table dependent's reference to its
  anchor is strong, as any field would be. A subtree nobody outside holds
  is therefore an ordinary cycle and dies as a whole when the collector
  finds its root (decision 3). A function, coroutine or userdata
  dependent does **not** keep its anchor alive: its state lives outside
  it, in a record that names the anchors weakly, so an anchor that only
  its non-table dependents refer to is collected, and its cascade kills
  them with reason `"anchor"` while something may still hold them. The
  promise of `f @ a` (`f` dies when `a` dies) holds either way; what the
  table case adds (`a` lives while `f` does) is a side effect of state
  inside the object, and the hosts give no way to have it without a leak
  ([05-decisions.md](05-decisions.md), "Non-table dependents: remembered
  after death, weak anchors"). Such a dependent carries no sentinel
  either: one the collector finds dies silently, its type's `__destroy`
  not run, as an unseen table does.
- `collectgarbage` keeps all of its Lua 5.1 options; nothing is removed.

Everything else stays exact and synchronous: anchored lifetimes, scope
exit, `lifetime.destroy`, the cascade order, hooks and destructors run by them.

## Coroutines

*From `xd/docs/03-destruction.md`, "Coroutines", as far as decisions 1 and
2 allow.*

A coroutine's stack is a chain of scopes; while it is suspended they are
alive and so is everything anchored to them. A coroutine the collector
finds unreachable cannot run its pending epilogues (5.1 has no
`coroutine.close`): the runtime destroys its scope records from the
finalizer, innermost first, and the Lua frames are dropped. A block that
anchors to `lifetime.scope` may yield on both hosts: the runtime puts no
`pcall` between a block and its body. An error that ends a coroutine
unwinds the coroutine's scopes, innermost first, inside the
`coroutine.resume` or the `coroutine.wrap` function that catches it,
before `false, err` is returned or the error is re-raised ("Scopes:
`lifetime.scope`"). A coroutine that died of an error keeps its frames
until it is collected, and the runtime holds it while it unwinds, so
the dependents of those scopes are reachable until their destructors
run, as they are for a `pcall` ([03-runtime.md](03-runtime.md), "The
scope stack and the error path"). A destructor body itself still cannot
yield on plain 5.1: the cascade calls it in protected mode to route its
error.

## Program end

*From `xd/docs/02-lifetimes.md`, "Program end", as far as the host allows.*

1. **The main scope exits** like any block: its dependents die in reverse
   attachment order, each with its cascade, reason `"anchor"`.
2. **The host closes the state.** Lua finalizes every object that still has
   a pending finalizer, newest first ("Host"); the runtime runs each one's
   cascade with reason `"exit"` when it has been told the program is ending
   (`lifetime run` tells it; how an embedding host tells it is open,
   [06-open-questions.md](06-open-questions.md)), else `"unreachable"`.

Newest first means an instance dies before the metatable it was created
with, so `__destroy` can still be found. `os.exit` on plain Lua 5.1 does
not close the state, so step 2 does not run after it; LuaJIT's
`os.exit(code, true)` does. There is no `os.exit` of our own.

## The `lifetime` table

*From `xd/docs/04-syntax.md`, "The `lifetime` table", reduced by decisions
5, 7 and 11 to the six names decision 11 lists, plus `lifetime.token`
and `lifetime.is_state`
([05-decisions.md](05-decisions.md), "Tokens are created by
`lifetime.token`").*

| Name | Meaning |
| --- | --- |
| `lifetime.reachable` | The `reachable` term as a lifetime value: `x @ lifetime.reachable` releases `x` to the collector; `lifetime.of(x)` of a default-lifetime object returns it. |
| `lifetime.scope` | The current block, as syntax: in anchor position the transpiler resolves the spelling to the block ("Scopes: `lifetime.scope`"). Read anywhere else it is a marker that cannot be anchored to. |
| `lifetime.token([name])` | A fresh token on the default lifetime ("Tokens: `lifetime.token`"). |
| `lifetime.pin(a1, …, an)` | A lifetime value over the anchors without the implicit `reachable` term ("The implicit `reachable` term"). |
| `lifetime.of(obj)` | `obj`'s current formula as a lifetime value, a snapshot: a later move of `obj` does not change it. Error on `nil`, a value, a dead object. |
| `lifetime.alive(x)` | The liveness check ("Tombstones"). |
| `lifetime.is_state(k)` | `true` when `k` is the key of the state record the runtime keeps inside every table it has seen ("`__destroy` and reasons", rule 7), `false` for anything else. `pairs` and `next` see that field as Lua shows it; a serializer or an emptiness check skips it with this test ([05-decisions.md](05-decisions.md), "The state record's key is a private table"). |
| `lifetime.dependents(obj)` | A fresh array of the live objects and hooks whose formula mentions `obj`, in attachment order. |
| `lifetime.format(v)` | A string rendering of a lifetime value, an object's formula, a token or a hook: `(conn, reachable)`, `conn` (pinned), `reachable`, `token period`, `scope`, `hook cleanup` for a named hook and `hook` for an anonymous one. Object anchors render through `tostring`, so a dead anchor in a snapshot renders as `dead <name>`. |

A **lifetime value** is a table with the private metatable `"lifetime"`:
no fields, no lifetime of its own. It holds its anchors strongly, so
holding a value keeps its anchors reachable. It is an immutable snapshot:
an anchor that dies stays in the value, and `@` on a value that mentions
a dead anchor raises `attempt to anchor to a dead table` (or `dead
token`), as writing that anchor directly would ([05-decisions.md](05-decisions.md),
"Lifetime values are immutable snapshots"). `==` on two values compares
structure. `lifetime.of(x)` on the default lifetime returns
`lifetime.reachable`, which when spliced refers to the reachability of the
object being anchored, not of `x`.

**Error texts** follow `xd/docs/04-syntax.md`, "Error texts": a runtime
error in the lifetime vocabulary reads `attempt to <verb> … <type> value`;
an argument error reads Lua's `bad argument #N to 'name' (<what> expected,
got <type>)`, with `name` the field's (`'destroy'`, `'of'`), as Lua
names a function called through a table field. "object" means a table, function, coroutine,
hook, token or userdata. Everything the standalone interpreter adds to a
message (a position prefix, a traceback) is Lua's own.

## Removals and changes relative to Lua 5.1

*From `xd/docs/04-syntax.md`, "Removals and changes relative to Lua",
reduced to what a transpiler can honour.*

- `lifetime.all`, `lifetime.any` and `lifetime.scope()` are gone: a
  conjunction is the list form after `@`, there is no disjunction, and
  scopes are syntax (decisions 5, 7 and 11).
- `@` is reserved and cannot appear in identifiers or elsewhere.
- `!@` is an operator, and `!` cannot appear anywhere else. The extension
  adds no reserved word: `defer`, `token`, `scope` and `caller` are
  ordinary names. The scope anchor is the spelling `lifetime.scope` in
  anchor position ([05-decisions.md](05-decisions.md), "The scope anchor
  is spelled `lifetime.scope`").
- `__gc` is not removed; the runtime uses it. A `__gc` of your own on a
  userdata still runs, as in Lua. Tables get `__destroy` through the
  runtime, not `__gc`.
- Nothing is removed from `collectgarbage`, `os.exit` or `coroutine`.

## Summary

| Object is… | Kept alive by | Killed by |
| --- | --- | --- |
| `@ lifetime.reachable` (the default) | being referenced | the collector, `lifetime.destroy()` |
| `@ a` | `a`, while something refers to the object | `a`'s death, the collector, `lifetime.destroy()` |
| `@ lifetime.scope` | the block, while referenced | block exit by any route, the collector, `lifetime.destroy()` |
| `@ (a, b)` | both, while referenced | whichever dies first, the collector, `lifetime.destroy()` |
| `@ lifetime.pin(a)` | `a` | `a`'s death, `lifetime.destroy()` |
| `@ lifetime.pin(a, b)` | both | whichever dies first, `lifetime.destroy()` |
| `f !@ a` | `a` | `a`'s death, `lifetime.destroy()`, cancelled by `lifetime.discard()` |
| `@ lifetime.of(x)` | what `x` had at that moment | any part failing, `lifetime.destroy()` |

Any row can be swapped for any other at run time by writing `@` again on
the live object.
