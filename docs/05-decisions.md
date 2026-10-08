# Decision log

Decisions made in this repository, with their reasons, in the style of
`xd/docs/07-decisions.md`. Decisions of `xd/docs/10-lua-lifetime-decisions.md`
are not repeated here and are not changed here. Newest at the bottom.

## The source file extension is `.lt`

File 10 left the extension open. A file with `@`, `defer` or `token` in it
is not valid Lua, so `.lua` would mislead every editor, linter and loader
that keys on the extension. Teal's `.tl` shows that a two-letter extension
works for a language that compiles to Lua, and `.lt` reads as "Lua,
lifetimes". Output files are `.lua`. `.lifetime` was rejected as long,
`.llt` as unpronounceable.
→ [04-transpiler.md](04-transpiler.md), `examples/README.md`

## Tokens are declared with `token NAME [@ anchor]` (superseded)

Decision 6 of file 10 calls for a declaration form and leans towards a
`token` keyword. Deriving [02-semantics.md](02-semantics.md) and the
grammar of [04-transpiler.md](04-transpiler.md) needed a production to
write down, and task 005 needs acceptance criteria that cite it, so the
bootstrap chose: `token NAME` is a statement that declares a local `NAME`
holding a fresh token, with the usual optional `@ anchor`, in the way
`local function NAME` declares a local. Reasons: a declaration gives the
token its name statically, so `tostring` and `lifetime.format` can render
`token period` without the runtime guessing; the statement shape makes a
token look like what it is, a named span of time, rather than a value
built by a call; and the leaning of file 10 was a keyword. An expression
form (`local p = token`) was rejected because a bare word that allocates
reads like a variable; a library function (`lifetime.token("period")`) was
rejected because decision 6 asked for a declaration and because the name
would be written twice. Whether `token` is reserved everywhere is a
separate open question ("Reserved words" in
[06-open-questions.md](06-open-questions.md)). Superseded below by
"Tokens are created by `lifetime.token`".

## The dead metatable raises

Decision 8 of file 10 left open whether a tombstone raises on access or
reads every field as `nil`, leaning towards raising with a message that
names the object and when it died. Decided as the leaning. Reading `nil`
would turn a use-after-death into the same silent `nil` that
`xd/docs/05-open-questions.md` ("Debug mode for nil-on-death") already
wanted to diagnose, and it would make a dead object indistinguishable
from an empty live one. Raising costs nothing on live objects and makes
lesson 4 of `xd/docs/09-lessons-from-treflove.md` (a nested `release()`
on a dead field) fail with a message that says what happened. The message
names the object through the `tostring` it had while alive, the source
position of the statement that caused the cascade, and the reason.
Identity comparison and raw access stay allowed so that an array can
still find and remove a tombstone, which decision 8 relies on.
→ [02-semantics.md](02-semantics.md), "Tombstones and `lifetime.alive`"

## `lifetime.pin` takes the list

Decision 11 of file 10 left open how `lifetime.pin` combines with the
list form, leaning towards `x @ lifetime.pin(a, b)`. Decided as the
leaning: `pin` is a function that takes one or more anchors and returns a
lifetime value without the implicit `reachable` term; the parenthesised
list after `@` stays the only formula syntax, and pinning stays a
function, so the `lifetime` table holds exactly the six names decision 11
lists. A list mixes freely: `x @ (a, lifetime.pin(b))` carries the term,
because `a` adds it, and `x @ (lifetime.pin(a), lifetime.pin(b))` does
not. A `pin` keyword after `@` was rejected because it would be a second
way to write a formula.
→ [02-semantics.md](02-semantics.md), "The implicit `reachable` term and `lifetime.pin`"

## Performance is a priority, second only to correctness

Decided by the human on 2026-10-07, replacing rule 5 of the bootstrap
`CLAUDE.md` ("Performance is not a goal. Do not optimise."), which had
been copied from `xd`, where the stage 1 interpreter is a reference
implementation in Python. lua-lifetime is meant to run inside real
programs on LuaJIT, such as Treflove's frame loop, and a runtime that
makes every call and every block slower than plain Lua would not be used.
The order is: the spec, then ownership order, then speed, then brevity.
An optimisation never changes what a program observes; one that would is
a spec change. The principle is pay for what you use: code that does not
use the extension pays nothing, code that does pays as little as the
design allows, and the cost is measured by `make bench` against plain Lua
and against `master`, not argued.

What it changed at once, in the design: the dependents list is walked by
a numeric loop over the sequence range with compaction, not by a sort per
cascade; the generated chunk binds runtime functions to locals; the
`caller` prologue and epilogue are inline field updates on a
per-coroutine table that the runtime swaps on coroutine switches, not
calls; the sentinel is allocated lazily; no `debug.*` or
`coroutine.running` on a per-call path. What it did not change: the
semantics, reachability being the collector's, and the cascade order.
What it reopened: the per-block `pcall` wrapper, now the most expensive
thing the transpiler emits ([06-open-questions.md](06-open-questions.md),
"Catch-site unwinding"), and the per-call cost of `caller` on programs
that never use it ("The cost of `caller` on every call"). Task 010 adds
the benchmark harness, and every task's *Performance* section names what
it measures.
→ `CLAUDE.md`, rule 5; [03-runtime.md](03-runtime.md), "Performance";
[04-transpiler.md](04-transpiler.md)

## Hooks are made with the operator `!@`, not the keyword `defer`

Decided by the human on 2026-10-07 ("no keyword for that, but some kind
of operator", then "`local hook = function() print("exited") end !@
scope`"). `f !@ a` is `xd`'s `defer f @ a` written as one infix operator
with the precedence and right operand of `@`: `@` attaches an object to a
lifetime, `!@` attaches an action. The rest of `defer` carries over: the
hook is pinned by its anchors, runs after its anchor's `__destroy`, is
called with the reason, and is moved, destroyed and discarded like any
object. The extension adds no reserved word, so `defer` is an ordinary
name again (Treflove's `events/defer-manager.lua` names a local `defer`).

Two things change with the spelling:

- **The anchor is always written.** There is no bare form, so there is
  no default lifetime: cleanup at block exit is `f !@ scope`. The
  argument `xd/docs/07-decisions.md`, "`defer` stays as syntactic sugar",
  made for a keyword (a bare form needs a default no function could
  supply) does not arise. The cost is two more words for the most common
  hook; the gain is that every hook says when it runs.
- **No precedence rule of its own.** `defer` took the whole expression up
  to `@` so that `defer a or b` could not mean `(defer a) or b`
  (`xd/docs/07-decisions.md`, "`defer` takes the whole expression up to
  `@`"). A postfix operator at the lowest precedence applies to the whole
  expression on its left anyway: `a or b !@ s` hooks `a or b`.

Why `!@`: `!` is unused by Lua 5.1 to 5.4 and LuaJIT and is believed
unused by Teal ([06-open-questions.md](06-open-questions.md), "Teal and
`!@`"), so the two-character token collides with nothing; the `@` keeps
the lifetime vocabulary on one character; and the `!` marks the
difference from `@`, so a hook does not read as anchoring the function.
A C programmer's `a != b` gets a targeted error that suggests `~=`.

Considered and rejected, in this order:

- **A prefix `!f [@ a]`**, proposed first in the same pull request: it
  needed a default lifetime for the bare form and a precedence looser
  than every Lua operator, unlike any unary operator, to keep `!a or b`
  from meaning `(!a) or b`. The human preferred the infix form.
- **`~f`**: Lua 5.3+ and Teal use unary `~` for bitwise not.
- **A prefix `@f`**: a line starting with `@` after a line ending in an
  expression parses as a postfix `@` on that expression.
- **`f @@ a`**: the same shape as `!@`, but one mistyped character away
  from `@`, which would silently anchor the function instead of hooking
  it.
- **`a -> f`, `a => f`**: `-->` is a comment, so one missing space comments
  the hook out, and `=>` reads as a lambda.
- **`$f`, `&f`**: `$` reads as interpolation; binary `&` is bitwise and in
  Lua 5.3+ and Teal.

This departs from the spelling of `xd/docs/04-syntax.md` and
`xd/docs/06-hooks.md`, from the default lifetime of `defer` in
`xd/docs/06-hooks.md`, and from the wording of decisions 4, 5 and 11 of
`xd/docs/10-lua-lifetime-decisions.md`, which write `defer`. The human
carries it back to `xd`.
→ [02-semantics.md](02-semantics.md), "Hooks: the `!@` operator";
[04-transpiler.md](04-transpiler.md), "Grammar"

## A hook bound to a name carries the name

Decided at the human's request on 2026-10-07 ("I want the defers to be
named or to be able to be named … we should be able to destroy them").
`local hook = fn !@ self` followed by `destroy(hook)`, `discard(hook)` or
`hook @ other` is the documented way to hold a hook, and the hook gets a
name: a hook created as the value of `local NAME =`, `NAME =` or
`t.NAME =` carries `NAME`, rendered by `tostring` as `hook NAME`, by
`lifetime.format`, and in a tombstone's message. The name comes from the
binding, so dumps of what an object owns read as code; the transpiler
can do this because `!@` is syntax and it sees the binding. (A token's
name is passed explicitly to `lifetime.token`, which is a plain call.) A separate naming
syntax (a name inside the operator, a `hook NAME = …` declaration) was rejected: binding
to a local is what a handle needs anyway, and a second spelling would add
syntax for a debugging aid. The name is a constant string passed at the
creation site and costs nothing per call.
→ [02-semantics.md](02-semantics.md), "Named hooks"

## Tokens are created by `lifetime.token`

Decided by the human on 2026-10-07 ("Token should be in the module
lifetime.token"), superseding "Tokens are declared with `token NAME`"
above. `lifetime.token([name])` returns a fresh token on the default
lifetime, and `@` anchors it like any object: `local period =
lifetime.token("period") @ self`. The name is an optional string for
display only (`tostring`, `lifetime.format`, tombstone messages).

Why: a token is a value with identity, held in fields and destroyed from
anywhere (decision 6's own reason it cannot be a marking), which a
function returns as naturally as `setmetatable` does; the extension's
syntax stays at `@`, `!@`, `scope` and `caller`; `token` is no longer a
word the parser has to treat specially, so Treflove's 41 uses of `token`
as an identifier need no rule; and the name the earlier entry rejected
the function for ("the name would be written twice") is now optional and
written once, as the argument.

This departs from decision 6 of `xd/docs/10-lua-lifetime-decisions.md`,
which decides that named tokens get "their own declaration form" and
leans towards a `token` keyword. The token itself is unchanged: identity,
a dependents list, a hook list, no fields, no metatable access. The
human carries the departure back to `xd`. The `lifetime` table grows by
one name, `token`, beside the six decision 11 lists; it builds an
object, not a formula, so decision 11's "everything that builds a formula
is syntax" still holds.
→ [02-semantics.md](02-semantics.md), "Tokens: `lifetime.token`"

## Base-class destructors are chained by hand; `__destroy` is found like a method

Decided by the human on 2026-10-07, settling the open point "Base-class
destructors" of `xd/docs/10-lua-lifetime-decisions.md`. The runtime looks
`__destroy` up with an ordinary index on the object's metatable, so it is
inherited through any depth of `__index` chain and through a function
`__index`, and calls that one function. A class that overrides it calls
its base by hand.

Checked under Lua 5.1 and LuaJIT: Lua follows `__index` through every
level for ordinary indexing (and stops with `loop in gettable` past 100
levels), calls a function `__index`, but reads its own metamethods
(`__tostring`, `__add`, `__gc`) raw, so they are not inherited. `__destroy`
is the runtime's, not Lua's, so the runtime picks the rule.

Rejected: walking the chain and calling every distinct `__destroy`
most-derived first (the leaning of file 10). The walk can only follow
`__index` while it is a table, so it stops at a function `__index` and
cannot walk a merged-index library such as Treflove's; it would run some
base destructors and skip others depending on how a class library is
built, run a base twice in code that already chains by hand, and cost a
walk per death. Also rejected: a raw lookup, Lua's metamethod rule, under
which a subclass without its own `__destroy` silently skips its base's
cleanup. Treflove chains constructors by hand already (64 `Base.init(self,
…)` calls), so chaining destructors the same way is what its code expects;
lesson 3 of `xd/docs/09-lessons-from-treflove.md` (one destructor per
metatable) stands, with the class library as the place that chains.
→ [02-semantics.md](02-semantics.md), "`__destroy` and reasons", rules 1 and 6

## The order of deaths the collector finds is undefined, for now

Decided by the human on 2026-10-08 ("Let's make destruction order
undefined for now - this is true C++ spirit"). When one collection finds
several objects unreachable, the order in which their cascades run is
undefined; so is the order of the program-end sweep and of the scope
records of a collected coroutine, which are the same mechanism. The order
of every death the program causes is unchanged: `destroy`, scope exit and
an anchor's death run body first, then dependents most recently attached
first, then the tombstone (decision 10).

What prompted it: a prototype of the runtime of
[03-runtime.md](03-runtime.md), run under Lua 5.1 and LuaJIT, showed that
a dependent gets its sentinel after its owner does, so Lua's newest-first
finalization destroys the dependent first. A connection and its buffer
dropped together gave `buf body (unreachable)`, then `conn body`, whose
`self.buf` was already a tombstone. The same probes confirmed that the
object a sentinel guards is fully intact in its finalizer, that weak
tables keep it until the next collection, and that a file opened after
the object was anchored is already closed when its destructor runs.

A fix exists and was verified in the same prototype, deferring once
([06-open-questions.md](06-open-questions.md), "A defined order for
deaths the collector finds"). It was not adopted now because it costs a
proxy per deferral, a wrapped `collectgarbage` and a cycle of delay for a
lone dependent, and because nothing yet shows a program that needs it:
Treflove destroys its trees explicitly. An undefined order can be defined
later without breaking any program; the reverse is not true.

Consequences: a destructor run with reason `"unreachable"` or `"exit"`
relies only on itself and its fields, and checks its dependents with
`lifetime.alive`; tests assert that each object found by a collection
died once with the right kind of reason, never their relative order;
examples never depend on that order. This departs from decision 3 of
`xd/docs/10-lua-lifetime-decisions.md`, whose proposal A has the root's
cascade take an unreferenced subtree "with reason `anchor`", from
decision 10's "my dependents are still here" for collector deaths, and
from the newest-first program-end order of `xd/docs/02-lifetimes.md`. The
human carries it back to `xd`.
→ [02-semantics.md](02-semantics.md), "Reachability is the collector's",
"Cascading death", "Program end"
