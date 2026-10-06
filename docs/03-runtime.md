# The runtime: `require("lifetime")`

The runtime is the `lifetime` table of [02-semantics.md](02-semantics.md)
and the bookkeeping behind it. This page is its design, derived from the
host facts of decision 1 of `xd/docs/10-lua-lifetime-decisions.md` and from
decisions 2, 3, 4, 8 and 10. Tasks 002 to 004 implement it; where this page
and a task disagree, [02-semantics.md](02-semantics.md) decides and this
page is corrected.

## What the host forces

| Host fact (decision 1) | What it forces |
| --- | --- |
| No `<close>`, `goto` only on LuaJIT | Scope exit is generated code ([04-transpiler.md](04-transpiler.md)); the runtime only provides `enter`/`exit` for scope records. |
| `__gc` on userdata only | A table whose destructor must run when the collector finds it carries a `newproxy(true)` sentinel ("The sentinel"). |
| No ephemerons | No side table keyed by anchor. Dependents live inside the anchor (decision 3). The only side table is weak-keyed with values that never refer back to the key. |
| No yield across `pcall` on plain 5.1 | The runtime never wraps user code in `pcall` on a path a coroutine may yield through; destructor bodies are called in protected mode only where 02 says errors are routed. |
| Finalizers run in reverse creation order | The collector's order of 02, "Reachability is the collector's", comes for free. |
| A finalized object stays in weak tables one more cycle | The cascade unlinks a dying dependent from its anchors' lists explicitly; it never waits for the weak entry to clear. |

## The state of an object

An object the runtime has seen (02, "`__destroy` and reasons", rule 7)
carries a **state record** in a hidden field of the table itself, created
on first contact. The field's key is a value private to the runtime; it
is visible to `pairs` and `next` (see
[06-open-questions.md](06-open-questions.md), "The hidden field is
visible"). The record holds:

- `formula`: the anchors (strong references) and whether the `reachable`
  term is present, plus, per anchor, the sequence number under which this
  object sits in that anchor's list.
- `seq`: the next attachment sequence number this object hands out as an
  anchor.
- `dependents`: a **weak-valued** table, sequence number to dependent.
  Weak values get holes when a dependent is collected, so iteration
  collects the keys, sorts them, and walks in that order with `pairs`,
  never `ipairs` (decision 4).
- `hooks`: a **strong-valued** table, sequence number to hook (decision
  4: a hook is pinned by its anchor).
- `sentinel`: the `newproxy(true)` sentinel, or `nil` ("The sentinel").
- `phase`: `nil`, `"dying"` or `"dead"`.
- `name`: `tostring(obj)` captured when the object starts dying, for the
  tombstone's message.

A dependent that is not a table (a function, coroutine or userdata) has
no hidden field; its state record lives in a weak-keyed side table whose
value refers to the dependent's anchors, never to the dependent itself,
so no cycle passes through the weak key. Such an object cannot be an
anchor (02, "Vocabulary").

Tokens, scope records and hooks are runtime tables with a state record
and a private metatable (`__metatable` set to `"token"`, `"scope"`,
`"hook"`), so `getmetatable` is the type test and `setmetatable` is
refused. A lifetime value is a table with the metatable `"lifetime"`
holding anchors and the term flag.

## Attachment: what `@` does

`lifetime.attach(obj, pin, a1, …, an)` (the exact name is the emitter's,
[04-transpiler.md](04-transpiler.md)) performs steps 1 to 4 of 02,
"Acquiring a lifetime":

1. Validate `obj` (an object, not dying, not dead; during a destroy phase,
   on the default formula or created in this phase).
2. Validate each anchor (live table, token or scope record; a lifetime
   value is spliced; `lifetime.reachable` sets the term).
3. Unlink `obj` from every old anchor's `dependents` under its old
   sequence number.
4. Link `obj` into each new anchor's `dependents` under `anchor.seq`,
   incremented, and store the formula.
5. Install the sentinel if the formula has the `reachable` term and the
   object is a table ("The sentinel").

Hooks go into `hooks` instead of `dependents` under the same sequence
counter, so `lifetime.dependents` and the cascade can merge the two lists
by sequence number into one attachment order (02, "`defer` and hooks").

## The cascade

`destroy`, `discard`, scope exit and the sentinel's finalizer all call one
function, `cascade(root, reason, where)`, which implements 02, "Cascading
death":

- **Decide.** Depth-first from `root` over `dependents` and `hooks`,
  marking `phase = "dying"`. With conjunction only there is no formula to
  re-evaluate: every dependent of a dying anchor dies. The dying set is
  closed when the walk returns.
- **Destroy.** Post-body order per object: run the body (`__destroy` with
  `(obj, reason)`, or a hook's function with `(reason)`), then walk the
  merged lists newest sequence number first, recursing into each entry
  still `"dying"` with reason `"anchor"`, then tombstone the object:
  unlink it from its anchors' lists, clear every field, set the dead
  metatable, `phase = "dead"`, and record `reason` and `where` for the
  tombstone's message.
- **Errors.** The first error of the cascade is held in a local and
  re-raised after the walk; later ones go to `destroyerror`, looked up raw
  in `_G`. A nested `destroy` inside a body is a cascade of its own (02,
  "Errors in destructors").
- **Phase guard.** A counter of running destroy phases tells `attach`
  whether "No moves during destruction" applies, and a per-phase set of
  objects created during the phase (recorded on first contact) tells it
  which objects are exempt.

`where` is the source position of the statement that caused the death:
`destroy` reads it with `debug.getinfo(2, "Sl")`; the generated epilogue
passes the line of the block exit; the finalizer passes `"collector"`.

## The tombstone

The dead metatable has `__index`, `__newindex` and `__call` raising the
message of 02, "Tombstones", built from the state record; `__tostring`
rendering `dead <name>`; `__metatable = "dead"`; and no `__eq`, so
identity comparison stays raw. Clearing the table (`for k in pairs(t) do
t[k] = nil end`, legal in Lua while iterating) is what makes the tombstone
cheap to keep: an emptied table costs its header. The state record is
reduced to what the message needs.

## The sentinel

`newproxy(true)` returns a zero-size userdata with its own fresh
metatable, on both Lua 5.1 and LuaJIT. The runtime stores the owning table
in that metatable (`getmetatable(proxy).owner = obj`) and sets
`__gc` to the finalizer; the table holds the proxy in its state record.
The cycle proxy → metatable → table → proxy is an ordinary strong cycle:
when the table becomes unreachable so does the proxy, Lua resurrects the
proxy and everything it references for the finalizer, and the finalizer
reaches the table through `getmetatable(proxy).owner`. No side table is
needed, which is what decision 3 requires.

The finalizer runs `cascade(obj, "unreachable", "collector")` if the
object is still `"dying"`-eligible (not already dead through an earlier
walk of the same collection, which the reverse-creation order makes
common), with the exit flag of "Program end" turning the reason into
`"exit"`. Which objects carry a sentinel:

- a table whose formula has the `reachable` term and that has a
  `__destroy`, dependents or hooks, because its collection must run a
  cascade;
- a scope record, so that the records of a collected suspended coroutine
  are destroyed (decision 2);
- a token with the `reachable` term;
- never a hook (pinned by its anchor) and never a pinned object.

Allocating a proxy per anchored object is the cost of reachable-only
destructors; a program that pins everything pays nothing.

## Scope records and `caller`

A **scope record** is a runtime table the generated block prologue
creates (`lifetime.enter()`) and the epilogue destroys
(`lifetime.exit(record, line)`): a cascade with the record as root, no
body, reason `"anchor"` for its dependents. `@ scope` in the block compiles
to an attachment to that record.

`caller` uses a **depth counter**, per coroutine (keyed by
`coroutine.running()`), as decision 5 describes: every generated function
prologue increments it and the epilogue decrements it and destroys the
record at that depth if one exists. A callee's `@ caller` asks
`lifetime.caller()` for the record at `depth - 1`, allocating it on first
use, so a call that never uses `caller` costs one increment and one
decrement. Two things this design leaves open are recorded in
[06-open-questions.md](06-open-questions.md): the record belongs to the
calling function's activation, not to its innermost block as decision 5
words it; and an error that unwinds through generated prologues without a
`pcall` wrapper leaves the counter stale.

## Tokens

`lifetime.token(name, pin, a1, …)` creates a token: a table with a state
record, the metatable `"token"`, and the name for `tostring` and
`lifetime.format`. It is attached like any object, with the implicit term
unless pinned, and gets a sentinel under the same rule as a table.

## Program end

`lifetime run` sets an exit flag after the main chunk has returned and its
scope epilogue has run; from then on the sentinel finalizers that the
closing state runs report `"exit"`. How an embedding host sets the flag is
open ([06-open-questions.md](06-open-questions.md)).

## What this costs

- One hidden field per object the runtime has seen, visible to `pairs`.
- One `newproxy` per table with the `reachable` term and a destructor, and
  per scope record that is created.
- A sort of the dependents' sequence numbers at every cascade and every
  `lifetime.dependents` call.
- The depth counter: one increment and one decrement per generated
  function call that contains a call.

All accepted; none of it is optimised in the first implementation.
