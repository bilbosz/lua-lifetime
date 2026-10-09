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

### The hidden field is visible

Decision 3 puts the state record in a hidden field of the object. `pairs`,
`next` and serializers see it: Treflove's `table.to_string` would write it
into `save.lua`, and `next(t) == nil` is no longer "empty" for a table the
runtime has seen. *Leaning:* a private table as the key, which no
serializer can mistake for data, and a documented `lifetime.is_state(k)`
rule for skipping it; to be settled by task 002 with the human.

### Teal and `!@`

The hook operator `!@` was chosen partly because Teal is believed not to
use `!`. The session that chose it could not reach Teal's sources to
confirm. Before `teal-lifetime` starts, check Teal's lexer for `!` and record the
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

### Iterating dependents without `pairs`

Decision 4 says the runtime "iterates in that order with `pairs`, never
`ipairs`". The runtime design walks the weak-valued list with a numeric
loop over its sequence range, skipping holes, which keeps what the
sentence protects (a hole never ends the walk, the order is attachment
order) and avoids a sort per cascade and a `pairs` walk. The letter of
the decision differs; confirm, and carry the wording back to `xd`.
