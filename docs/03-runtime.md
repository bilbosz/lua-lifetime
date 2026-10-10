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
| No yield across `pcall` on plain 5.1 | The runtime puts no `pcall` between a block and its body: the error path unwinds at the catch site ("Scope records"), so a scoped block may yield. Destructor bodies are called in protected mode only where 02 says errors are routed. |
| Finalizers run in reverse creation order | The collector's order of 02, "Reachability is the collector's", comes for free. |
| A finalized object stays in weak tables one more cycle | The cascade unlinks a dying dependent from its anchors' lists explicitly; it never waits for the weak entry to clear. |

## The state of an object

An object the runtime has seen (02, "`__destroy` and reasons", rule 7)
carries a **state record** in a hidden field of the table itself, created
on first contact. The field's key is one table the runtime creates when
it is loaded and never hands out, so no user field can collide with it
and no serializer can mistake it for data; `lifetime.is_state(k)` is
true for that key and nothing else ([05-decisions.md](05-decisions.md),
"The state record's key is a private table"). The field is visible to
`pairs` and `next` as Lua makes it: the runtime sets no `__pairs` (5.1
has none) and leaves `#`, `next` and `rawequal` alone, so a loop that
must skip the record writes `if not lifetime.is_state(k)`. The record
holds:

- `formula`: the anchors (strong references) and whether the `reachable`
  term is present, plus, per anchor, the sequence number under which this
  object sits in that anchor's list.
- `seq`: the next attachment sequence number this object hands out as an
  anchor, and `lo`, the lowest sequence number that may still hold an
  entry.
- `dependents`: a **weak-valued** table, sequence number to dependent.
  Weak values get holes when a dependent is collected or detached, so
  iteration is a numeric loop `for i = seq - 1, lo, -1`, skipping `nil`
  slots: newest first, never stopped by a hole as `ipairs` would be
  (decision 4), and never a sort. Sequence numbers only grow, so the order
  is the attachment order without any bookkeeping. When holes outnumber
  live entries the runtime **compacts**: it renumbers the live entries
  densely from `lo`, in order, updates each dependent's stored sequence
  number, and resets `seq`. Compaction is amortised over the detaches that
  made the holes and never runs during a cascade.
- `strong`: a **strong-valued** table, sequence number to hook or pinned
  dependent. A hook is pinned by its anchor (decision 4), and a dependent
  whose formula carries no `reachable` term (`@ lifetime.pin(a)`) is
  "alive while `a` is, referenced or not" (02), so the anchor is what
  holds it; everything with the term lives in the weak `dependents`
  table instead. The two tables share one sequence counter and are
  merged by sequence number wherever the attachment order matters
  ([05-decisions.md](05-decisions.md), "Pinned dependents are held by
  their anchors").
- `sentinel`: the `newproxy(true)` sentinel, or `nil` ("The sentinel").
- `phase`: `nil`, `"dying"` or `"dead"`.
- `name`: `tostring(obj)` captured when the object starts dying, for the
  tombstone's message.

As implemented (task 002, review finding F1): the record's fixed fields
are `n` (the number of anchors), `reachable`, `deps`, `phase`,
`phase_id` (the destroy phase in which the runtime first saw the object,
for "No moves during destruction"), `name`, `where` and `reason`, with
the anchor pairs `[2i-1] = anchor, [2i] = sequence number` in the array
part; `seq`, `lo` and `limit` (the amortised compaction limit) live in the
anchor's weak `deps` table rather than in the record, so an object that
is never used as an anchor pays nothing for them. The names above
(`formula`, `dependents`, `strong`, `sentinel`) are the design's; `deps`
is the weak table, and task 004 adds `strong` and the sentinel beside it.

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

Hooks and pinned dependents go into `strong` instead of `dependents`
under the same sequence counter, so `lifetime.dependents` and the cascade can merge the two lists
by sequence number into one attachment order (02, "Hooks: the `!@` operator").

## The cascade

`destroy`, `discard`, scope exit and the sentinel's finalizer all call one
function, `cascade(root, reason, where)`, which implements 02, "Cascading
death":

- **Decide.** Depth-first from `root` over `dependents` and `strong`,
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
`destroy` and `discard` read it with `debug.getinfo(2, "Sl")` once per
call, since every tombstone's message carries it (02, "Tombstones"); that
is one `debug` call per explicit destruction, never per block entry or
per attach, and it is off the plain-Lua path; the generated epilogue
passes the line of the block exit as a constant; the finalizer passes
`"collector"`.

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

The finalizer runs `cascade(obj, "unreachable", "collector")` in
protected mode, routing every error of the cascade to `destroyerror` (02,
"Errors in destructors": a finalizer has no statement to raise at, and
Lua 5.1 would surface the error at an unrelated allocation), if the
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
- a hook only when its formula is `lifetime.reachable` alone (`f !@
  lifetime.reachable`): it has no anchor to die with, so the collector
  runs it with reason `"unreachable"` (02, "Hooks": "may run `f` at any
  later time"); any other hook is pinned by its anchor and never carries
  one, and never a pinned object.

Allocating a proxy per anchored object is the cost of reachable-only
destructors; a program that pins everything pays nothing. The proxy is
armed lazily, on the first `@` that makes the object need one (an object
seen only as an anchor gets its proxy at its first link), not at
`setmetatable`; a move that drops the term disarms it and one that brings
the term back arms another. As implemented (task 004): the record holds
the proxy's metatable in its `reachable` field (a scope record in
`sentinel`); a disarmed proxy is kept by the runtime in its slot and
reused for a later owner, never twice for the same object and never while
its finalizer is pending, so the position of each proxy, and with it the
host's finalization order, is the order of the `@`s that armed them
(a fresh `newproxy` per object costs 400 to 600 ns more). A finalizer
that fires inside a runtime operation is queued and run when the
operation ends; a foreign `__gc` that raises through such an operation
leaves the guard set until the next operation, which delays, never
loses, the finalizers queued in between.

## Scope records

A **scope record** is a runtime table the generated block prologue
creates (`lifetime.enter()`) and the epilogue destroys
(`lifetime.exit(record, line)`): a cascade with the record as root, no
body, reason `"anchor"` for its dependents. `@ lifetime.scope` in the block compiles
to an attachment to that record. The transpiler resolves `lifetime.scope`
statically, so a record exists only for a block that anchors to it, and
only while that block is active. The runtime's own field `lifetime.scope`
is the marker of 02, "Scopes: `lifetime.scope`": a table with a private
metatable whose `__index`, `__newindex` and `__call` raise `attempt to
index lifetime.scope`, whose `__tostring` is `lifetime.scope`, and which
`attach` refuses with `attempt to anchor to lifetime.scope through a
variable`. It is never a scope record.

Nothing runs per call. There is no anchor for the calling function's
block ([05-decisions.md](05-decisions.md), "`caller` is removed"), so the
runtime keeps no depth counter and gives generated functions no prologue
or epilogue of their own.

**The scope stack and the error path.** Scope exit on an error is the
runtime's, not generated code's ([05-decisions.md](05-decisions.md),
"Scopes unwind at the catch site"). Each coroutine has a **scope stack**,
a table `{n = depth, [1..n] = records}`; `S.stack` is the stack of the
running coroutine, and the main thread's is the initial one. The block
prologue `lifetime.enter(line)` creates the record, stores `line` (the
line of the block's `end`, for the tombstones of an unwound record) and
its depth, and pushes it; the epilogue `lifetime.exit(record, line)` pops
it and runs the cascade. If `exit` finds records above `record` on the
stack, a catch the runtime could not see left them behind: it unwinds
them first, innermost first, then proceeds.

When it is first required the runtime replaces four globals, keeping the
originals as upvalues: `pcall` and `xpcall` read `S.stack.n` before the
call and, when the call returns `false`, unwind every record above that
depth, innermost first, with the error counted as propagating (02,
"Errors in destructors": destructor errors go to `destroyerror`), then
return what the original returned. `coroutine.resume` swaps `S.stack` to
the target coroutine's stack (created on first resume, held in a table
weak in both keys and values, keyed by coroutine; each record holds its
stack, so a stack lives exactly while its coroutine is running or has an
active record, and a hook that closes over its own coroutine cannot keep
the coroutine alive through the table, which Lua 5.1's lack of
ephemerons would otherwise allow) for the duration of the call and
restores it after, which covers the yield
path without wrapping `coroutine.yield`; when the original returns
`false` the coroutine is dead and its whole stack is unwound.
`coroutine.wrap` creates through the original and returns a function
that resumes the same way and re-raises as Lua's does. The wrappers pass
varargs through and allocate nothing. Each is a wrapper and its
continuation, two Lua vararg frames, since a single frame cannot inspect
the first result without packing the rest; the measured cost is in
"Performance". Records a hidden catch left behind in a suspended
coroutine with no active record above them are collected with their
stack and die through their sentinels, not at a later exit. `coroutine.running`, `coroutine.status`,
`coroutine.create`, `coroutine.yield` and `error` are untouched.

A coroutine the collector finds unreachable drops its stack with it; the
records of a suspended coroutine are then reached only through their
sentinels ("The sentinel"), which run innermost first by the host's
reverse creation order.

## Tokens

`lifetime.token([name])` creates a token: a table with a state record,
the metatable `"token"`, and the name (or `nil`) for `tostring` and
`lifetime.format`. It starts on the default lifetime; generated code
anchors it with `attach` like any object, with the implicit term unless
pinned, and it gets a sentinel under the same rule as a table.

## Hooks

`lifetime.hook(f, name, a1, …)` creates a hook: a table with a state
record, the metatable `"hook"`, the function, and the name (a constant
string the emitter passes for a named hook, `nil` otherwise). It is
attached pinned to its anchors and linked into each anchor's `strong`
list, never into `dependents`, so the anchor holds it strongly; it never
carries a sentinel. Its body calls `f(reason)`. Naming costs one string
constant per creation site and nothing per call.

## Program end

`lifetime run` sets an exit flag after the main chunk has returned and its
scope epilogue has run, and after an uncaught error has been reported;
from then on the sentinel finalizers that the closing state runs report
`"exit"`. The entry point is `lifetime.set_exiting(flag)`; `lifetime run`
calls it, and an embedding host calls it from its own quit path (how a
host such as LÖVE reaches it is still open:
[06-open-questions.md](06-open-questions.md)). A suspended coroutine's
scope record finalized at state close gives a dependent that has no
sentinel of its own (a pinned object, a hook) the reason `"anchor"`, as the
main scope's exit does; a dependent with its own, newer sentinel dies
`"exit"` first.

## Performance

Performance is a priority second only to the spec and ownership order
(`CLAUDE.md`, rule 5; [05-decisions.md](05-decisions.md), "Performance
is a priority"). The runtime is designed to the following budget, and
`make bench` (task 010) measures each line against plain Lua doing the
same work by hand.

**Free.** Code that does not use the extension pays nothing:

- a plain Lua chunk transpiles to itself;
- an object never anchored, hooked, created by `lifetime.token` or passed to
  `destroy`, `discard` or `lifetime.of` has no state record and no proxy;
- a block with no `@ lifetime.scope` and no `!@ lifetime.scope` gets no scope record, no
  push and no pop;
- a function call costs what it costs in Lua: no generated function has
  a prologue or an epilogue of its own ("Scope records").

**Cheap.** What the extension costs where it is used:

| Operation | Cost |
| --- | --- |
| `x @ a`, first time | one state record, one link into `a`'s `dependents`; one proxy if `x` needs a sentinel |
| `x @ b`, a move | one unlink, one link; no allocation |
| cascade over `n` objects | `O(n)` plus the holes in the walked ranges; no sort, no allocation except the tombstone's state |
| `lifetime.dependents(a)` | one numeric loop over `a`'s range and the result array |
| a block with a scope record | one record (a small table) per entry, one push and one pop; no closure, no `pcall` ("The scope stack and the error path") |
| `pcall`, `xpcall`, `coroutine.resume`, a `coroutine.wrap` function | one wrapper frame, one field read before and one compare after; no allocation |

**Forced, and measured.** Two costs follow from the spec and are paid
only where the spec asks for them:

- the sentinel, one `newproxy(true)` per table that has the `reachable`
  term and something to run at collection, armed and disarmed as the
  formula changes; measured (task 004): about 50 ns per object on LuaJIT
  and 120 ns on Lua 5.1 on top of the 350 ns an attach-and-destroy costs
  without it, so `runtime/attach-destroy-100` and `runtime/cascade-tree`
  read 1.13 to 1.16 under LuaJIT and 1.04 to 1.08 under Lua 5.1 against a
  runtime without sentinels; `make bench` marks the LuaJIT rows `SLOWER`
  against such a base, and that mark is the design's. A collection that
  runs 100 cascades costs 10x (Lua 5.1) and 5x (LuaJIT) a silent one;
  `lifetime.alive` is 111 ns per call on Lua 5.1 and 3 ns on LuaJIT;
- the scope record and its push and pop, per entry into a block that
  anchors to `lifetime.scope`. Nothing the transpiler emits creates a
  closure or a `pcall`, so a loop whose body owns something stays
  compilable by LuaJIT; measured (task 003, ns per 10 operations, Lua
  5.1 / LuaJIT): a loop body owning one object 27 600 / 4 300, an empty
  `enter`/`exit` 4 500 / 920, a hook on a scope 24 500 / 3 850;
- the four replacements for `pcall`, `xpcall`, `coroutine.resume` and
  `coroutine.wrap`, two Lua frames each where the host had a C function;
  measured (task 003): on Lua 5.1 `pcall` of an empty function 120 vs 53
  ns, `pcall` with an error 216 vs 123 ns, `resume`/`yield` 176 vs 75 ns;
  on LuaJIT 2.6 vs 2.1 ns, parity, 64 vs 48 ns. `make bench` marks them
  `SLOWER` against a base without the runtime; that mark is the design's,
  not a regression.

Rules the implementation follows on hot paths: runtime functions are
locals of the module, and the generated chunk binds the ones it calls to
locals; numeric `for` loops, not `pairs`, over runtime tables; no
`debug.*`, `coroutine.running` or `select("#", …)` on a path that runs per
block entry (the line number for a tombstone's message is a
constant the emitter passes, not `debug.getinfo`); one state record per
object, its fields fixed so LuaJIT keeps the table shape stable.

What stays deliberately simple, because it is not on a hot path: error
messages, `lifetime.format`, compaction, and the program-end sweep.
