# Open questions

Not decided. Each entry says where it came from and the current leaning
where there is one. Questions that file 10 of `xd`
(`xd/docs/10-lua-lifetime-decisions.md`) lists as open points are this
repository's to settle and report back; questions that touch a decision of
file 10 are reported to the human, who carries them back to `xd`, and are
not settled here (see `.claude/skills/spec-change/SKILL.md`). Settled
questions move to [05-decisions.md](05-decisions.md).

## From the open points of file 10

### Base-class destructors

Decision 10. C++ runs the derived body, then the base bodies. *Leaning
(file 10):* the runtime walks the metatable `__index` chain while it is a
table, collects every distinct `__destroy`, and calls them most-derived
first. A merged-index class library, as Treflove's, cannot be walked and
chains its own; lesson 3 of `xd/docs/09-lessons-from-treflove.md` (one
destructor per metatable) stays for it unless the library exposes its base
list.

### Whether a hook or destructor learns which anchor died

Proposal D of `xd/docs/09-lessons-from-treflove.md`. `remaining` is gone
(decision 10), so the argument after `reason` is free. *Leaning:* pass the
anchor whose death caused this one as a second argument to hook functions
and a third to `__destroy`; `nil` for `"destroy"`, `"unreachable"` and
`"exit"`.

### An ordered collection that compacts when a member dies

Proposal C of `xd/docs/09-lessons-from-treflove.md`. *Leaning:* a library
table in the runtime with a hook per member, not a change to arrays.

### `caller` across coroutine boundaries

Decision 5. The depth counter is per coroutine, so the calling function of
a coroutine body is the resumer or nothing. *Leaning:* the scope that was
active when the coroutine body started, as `xd/docs/05-open-questions.md`
leans for the caller's scope; that needs the record to be captured at
`coroutine.create`, which the runtime cannot see without wrapping
`coroutine`.

### Errors in finalizer-run destructors

Decision 2. Lua 5.1 propagates an error raised in `__gc` into whatever
allocation triggered the collection. *Leaning:* the sentinel's finalizer
calls the cascade in protected mode and routes every error to
`destroyerror`, as rule 5's second clause does for an error raised while
another is propagating; there is no statement to raise at.

## Found while deriving the spec

### Non-table anchors

Decision 3 keeps dependents inside the anchor, and Lua 5.1 gives only
tables a field to keep them in. [02-semantics.md](02-semantics.md)
therefore allows only tables and tokens as anchors; functions, coroutines
and userdata can be dependents but not anchors. `xd` allows any object.
Userdata have an environment table on 5.1 and LuaJIT (`debug.setfenv`),
which could hold the record. *Leaning:* tables and tokens only until a
real program wants a userdata anchor; LÖVE objects in Treflove are
dependents.

### Non-table dependents after death

Decision 8 tombstones a table by emptying it and swapping its metatable.
A dead function, coroutine or userdata cannot be emptied. The runtime
remembers the death in a weak-keyed set so that `lifetime.alive` and `@`
see it; calls and other uses are not caught. *Leaning:* accept; document.

### Registering plain objects

Under decision 2 the runtime can only notify objects it has seen. A plain
table with a `__destroy` that was never anchored, hooked or destroyed is
collected silently, unlike in `xd`, where every object is found.
[02-semantics.md](02-semantics.md), "`__destroy` and reasons", rule 7,
makes `x @ lifetime.reachable` the registration. *Leaning:* accept; a
class library registers its instances in its constructor, one line in
Treflove's `utils/class.lua`. Needs the human's confirmation since it is a
consequence of decision 2 that file 10 does not state.

### The hidden field is visible

Decision 3 puts the state record in a hidden field of the object. `pairs`,
`next` and serializers see it: Treflove's `table.to_string` would write it
into `save.lua`, and `next(t) == nil` is no longer "empty" for a table the
runtime has seen. *Leaning:* a private table as the key, which no
serializer can mistake for data, and a documented `lifetime.is_state(k)`
rule for skipping it; to be settled by task 002 with the human.

### `caller`: function granularity and the error path

Decision 5 says `caller` is "the innermost block of the calling function"
and that a function epilogue destroys the record, which is only possible at
function granularity: the record lives until the calling function returns,
not until its innermost block exits. And an error that unwinds through
generated prologues without a `pcall` wrapper leaves the depth counter too
high. *Leaning:* function granularity, stated as such; for the error path,
the runtime wraps `pcall`, `xpcall`, `coroutine.resume` and
`coroutine.wrap` at `require` time to save and restore the counter and to
destroy stale records innermost first. Both touch decision 5's wording and
go to the human.

### Catch-site unwinding instead of per-block `pcall` wrappers

If the runtime wraps `pcall` and friends anyway (above), scope records can
be kept on a per-coroutine stack and unwound at the catching `pcall`,
which removes the closure rewrite of `return`, `break` and `...`, the lost
tail calls inside wrapped blocks, and the yield restriction on plain 5.1.
The observable difference is only where an uncaught error leaves records
behind. Touches decisions 5 and 10, which name the per-block wrapper; goes
to the human.

Since performance became a priority ([05-decisions.md](05-decisions.md))
this is also the largest performance question in the design: the
per-block wrapper allocates a closure on every entry into a block with a
scope record, a loop body included, and it is the one cost the
transpiler adds that grows with how often a block runs rather than with
how many objects it owns. *Leaning:* catch-site unwinding, decided on the
numbers of the task 010 benchmark that runs a scoped block in a loop both
ways.

### Reserved words

The extension adds no reserved word: hooks are made with the `!`
operator ([05-decisions.md](05-decisions.md)), so `defer` is an ordinary
name and Treflove's `events/defer-manager.lua` keeps its local `defer`.
Treflove uses `token` as an identifier in 41 places (its game pieces are
tokens) and `scope` and `caller` nowhere. *Leaning:* `scope` and
`caller` are keywords only after `@` and inside the list form, where a
variable of that name could not be anchored to anyway; `token` is a
keyword only at statement start followed by a `Name`, which is never
valid Lua, so every existing use of `token` as a variable keeps working.
Decision 5 calls them keywords without saying reserved; settled by the
parser task with the human.

### Teal and `!`

The hook operator `!` was chosen partly because Teal is believed not to
use it. The bootstrap session could not reach Teal's sources to confirm.
Before `teal-lifetime` starts, check Teal's lexer for `!` and record the
answer here; if Teal uses it, the Teal front end needs another spelling or
Teal needs to give it up.

### How an embedding host announces program end

The CLI sets the exit flag so that finalizers at state close report
`"exit"`. A host such as LÖVE closes the state itself. *Leaning:* a
function on the runtime that the host calls from its quit callback; name
to be chosen when Treflove needs it (task 009).

### Program end on plain Lua 5.1 after `os.exit`

`os.exit` on plain 5.1 never closes the state, so no finalizer runs and
step 2 of "Program end" is skipped. LuaJIT's `os.exit(code, true)` closes
it. *Leaning:* document; no wrapper of `os.exit`.

### Lifetime values as a one-way gate

`xd` removes dead anchors from every lifetime value that mentioned them.
The runtime can only do this for values it can find, so a value would have
to be listed among its anchors' dependents and skipped by
`lifetime.dependents`. *Leaning:* list them; alternatively, refuse a value
with a dead anchor at `@` and keep snapshots immutable. Task 004 decides
with the human.

### The cost of `caller` on every call

Decision 5 gives every generated function a prologue and an epilogue so
that any callee can ask for `caller`. Inlined
([03-runtime.md](03-runtime.md), "Scope records and `caller`") that is a
handful of field operations per call, paid by programs that never write
`caller`, against the rule that code not using the extension pays nothing.
The transpiler cannot see across modules whether a callee uses `caller`.
Options: (a) keep the prologue everywhere; (b) a build flag, so a program
that does not use `caller` is built without it, and `@ caller` in a
module built with the flag reaching a caller built without it is the main
scope; (c) a pragma per module. *Leaning:* measure first (task 010); if
the prologue costs more than a few percent on a call-heavy benchmark,
(b). Touches decision 5's "every generated function prologue increments
it"; goes to the human.

### Iterating dependents without `pairs`

Decision 4 says the runtime "iterates in that order with `pairs`, never
`ipairs`". The runtime design walks the weak-valued list with a numeric
loop over its sequence range, skipping holes, which keeps what the
sentence protects (a hole never ends the walk, the order is attachment
order) and avoids a sort per cascade and a `pairs` walk. The letter of
the decision differs; confirm, and carry the wording back to `xd`.
