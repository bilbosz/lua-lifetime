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
