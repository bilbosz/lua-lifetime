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

## Tokens are declared with `token NAME [@ anchor]`

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
[06-open-questions.md](06-open-questions.md)).
→ [02-semantics.md](02-semantics.md), "Named tokens"

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

## Hooks are made with the prefix operator `!`, not the keyword `defer`

Proposed at the human's request on 2026-10-07 ("no keyword for that, but
some kind of operator"), adopted when the pull request that carries it is
merged. `!f` is the `defer f` of `xd` respelled; every rule carries over
unchanged: `!` takes the whole expression up to a `@`, a comma or a
closer; a bare `!f` defaults to the enclosing block's scope; `!f @ a` is
pinned by `a`; the hook runs after its anchor's `__destroy`. The
extension therefore adds no reserved word, and `defer` is an ordinary name
again (Treflove's `events/defer-manager.lua` names a local `defer`).

The operator is `!` because:

- it is unused by Lua 5.1, 5.2, 5.3, 5.4 and LuaJIT, so it collides with
  nothing a Lua programmer writes today; Teal is believed not to use it
  either, to be confirmed before `teal-lifetime` starts
  ([06-open-questions.md](06-open-questions.md), "Teal and `!`");
- Lua has no binary or postfix `!`, so a `!` at a line start always
  begins a statement and never continues the previous expression;
- it is one character, stands at the start of the statement where
  `defer` stood (the argument `xd/docs/07-decisions.md`, "`defer` stays as
  syntactic sugar", made for the keyword), and reads as "do this", as in
  Ruby's bang methods and Rust's macros.

Its cost is that C programmers read `!` as "not". On a function value
"not" has no meaning in Lua, and the one place a C habit lands on it,
`a != b`, gets a targeted error that suggests `~=`.

Considered and rejected:

- **`~f`** (the prefix `xd` considered): Lua 5.3+ and Teal use unary `~`
  for bitwise not, so `teal-lifetime` could not parse it.
- **`@f`**, prefix `@`, so that `@` is the whole vocabulary: a line that
  starts with `@` after a line ending in an expression parses as a
  postfix `@` on that expression, the same trap as Lua's ambiguous `(`;
  and `@f @ self` reads as noise.
- **`f @@ a`** or **`f @! a`**, a second postfix operator: the common case,
  cleanup at block exit, then needs `f @@ scope` written out or a special
  bare form, and the operator reads as anchoring the function rather than
  running it.
- **`a -> f`** or **`a => f`**, an arrow from lifetime to action: `-->` is
  a comment, so one missing space silently comments the hook out, and
  `=>` reads as a lambda.
- **`$f`**: free everywhere, but it reads as interpolation or a variable
  in shells and templates and says nothing about running later.
- **`&f`**: binary `&` is bitwise and in Lua 5.3+ and Teal.

This departs from the spelling of `xd/docs/04-syntax.md` and
`xd/docs/06-hooks.md` and from the wording of decisions 4, 5 and 11 of
`xd/docs/10-lua-lifetime-decisions.md`, which write `defer`; the
semantics are untouched. The human carries the spelling back to `xd`.
→ [02-semantics.md](02-semantics.md), "Hooks: the `!` operator";
[04-transpiler.md](04-transpiler.md), "Grammar"

## A hook bound to a name carries the name

Decided at the human's request on 2026-10-07 ("I want the defers to be
named or to be able to be named … we should be able to destroy them").
The expression form already returned the hook, so `local hook = !fn @
self` followed by `destroy(hook)`, `discard(hook)` or `hook @ other`
worked; this entry makes that the documented way to hold a hook and adds
the name: a hook created as the value of `local NAME =`, `NAME =` or
`t.NAME =` carries `NAME`, rendered by `tostring` as `hook NAME`, by
`lifetime.format`, and in a tombstone's message. The name comes from the
binding the way a token's name comes from its declaration (`token
NAME`), so dumps of what an object owns read as code. A separate naming
syntax (`!name: f`, a `hook NAME = …` declaration) was rejected: binding
to a local is what a handle needs anyway, and a second spelling would add
syntax for a debugging aid. The name is a constant string passed at the
creation site and costs nothing per call.
→ [02-semantics.md](02-semantics.md), "Named hooks"
