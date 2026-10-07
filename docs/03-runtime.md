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
by sequence number into one attachment order (02, "Hooks: the `!` operator").

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
`destroy` reads it with `debug.getinfo(2, "Sl")` only when the object it
destroys has dependents or a destructor to report about, which is off the
plain-Lua path; the generated epilogue passes the line of the block exit
as a constant; the finalizer passes `"collector"`.

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
destructors; a program that pins everything pays nothing. The proxy is
allocated lazily: on the first `@` that makes the object need one, not at
`setmetatable`, and never again for the same object.

## Scope records and `caller`

A **scope record** is a runtime table the generated block prologue
creates (`lifetime.enter()`) and the epilogue destroys
(`lifetime.exit(record, line)`): a cascade with the record as root, no
body, reason `"anchor"` for its dependents. `@ scope` in the block compiles
to an attachment to that record.

`caller` uses a **depth counter**, per coroutine, as decision 5
describes. For speed the counter is not reached through a call: the
runtime keeps one table `D` per coroutine, with the current depth in
`D.n` and the record of the activation at depth `d`, if one was asked
for, in `D[d]`, and a state table `S` whose field `S.D` is the `D` of the
running coroutine. The generated prologue and epilogue are inline
([04-transpiler.md](04-transpiler.md), "Functions: prologue and epilogue
for `caller`"):

```lua
local __D = __lt_S.D; local __d = __D.n + 1; __D.n = __d     -- prologue
if __D[__d] then __lt_drop(__D, __d) end; __D.n = __d - 1    -- epilogue
```

A call that never uses `caller` costs two field reads, two field writes
and one indexed read: no function call, no allocation. The epilogue
*assigns* the depth rather than decrementing it, so an error that skipped
inner epilogues and was caught inside this function is corrected when
this function returns. A callee's `@ caller` calls `lifetime.caller()`,
which returns `D[D.n - 1]`, allocating it on first use. `S.D` follows the
running coroutine because the runtime wraps `coroutine.resume`,
`coroutine.wrap` and `coroutine.yield` when it is first required and
swaps `S.D` on each switch; `coroutine.running` is never called on the
hot path. Two things this design leaves open are recorded in
[06-open-questions.md](06-open-questions.md): the record belongs to the
calling function's activation, not to its innermost block as decision 5
words it; and a record left behind by an error that was not caught until
an outer function is destroyed late, by the next prologue that reaches
its depth or by the catching function's epilogue.

## Tokens

`lifetime.token(name, pin, a1, …)` creates a token: a table with a state
record, the metatable `"token"`, and the name for `tostring` and
`lifetime.format`. It is attached like any object, with the implicit term
unless pinned, and gets a sentinel under the same rule as a table.

## Hooks

`lifetime.hook(f, name, a1, …)` creates a hook: a table with a state
record, the metatable `"hook"`, the function, and the name (a constant
string the emitter passes for a named hook, `nil` otherwise). It is
attached pinned to its anchors and linked into each anchor's `hooks`
list, never into `dependents`, so the anchor holds it strongly; it never
carries a sentinel. Its body calls `f(reason)`. Naming costs one string
constant per creation site and nothing per call.

## Program end

`lifetime run` sets an exit flag after the main chunk has returned and its
scope epilogue has run; from then on the sentinel finalizers that the
closing state runs report `"exit"`. How an embedding host sets the flag is
open ([06-open-questions.md](06-open-questions.md)).

## Performance

Performance is a priority second only to the spec and ownership order
(`CLAUDE.md`, rule 5; [05-decisions.md](05-decisions.md), "Performance
is a priority"). The runtime is designed to the following budget, and
`make bench` (task 010) measures each line against plain Lua doing the
same work by hand.

**Free.** Code that does not use the extension pays nothing:

- a plain Lua chunk transpiles to itself;
- an object never anchored, hooked, declared as a token or passed to
  `destroy`, `discard` or `lifetime.of` has no state record and no proxy;
- a block with no `@ scope` and no bare hook gets no scope record and no
  wrapper;
- a function whose body contains no call gets no `caller` prologue.

**Cheap.** What the extension costs where it is used:

| Operation | Cost |
| --- | --- |
| `x @ a`, first time | one state record, one link into `a`'s `dependents`; one proxy if `x` needs a sentinel |
| `x @ b`, a move | one unlink, one link; no allocation |
| cascade over `n` objects | `O(n)` plus the holes in the walked ranges; no sort, no allocation except the tombstone's state |
| `lifetime.dependents(a)` | one numeric loop over `a`'s range and the result array |
| `caller` prologue and epilogue | inline field updates, no call (above) |
| a block with a scope record | one record (a small table) per entry, plus the wrapper ([04-transpiler.md](04-transpiler.md), "The error path") |

**Forced, and measured.** Two costs follow from the spec and are paid
only where the spec asks for them:

- the sentinel, one `newproxy(true)` per table that has the `reachable`
  term and something to run at collection;
- the `pcall` wrapper of a block that needs a scope record, a closure per
  entry into the block. Whether the error path can be built without it is
  open ([06-open-questions.md](06-open-questions.md), "Catch-site
  unwinding"); the benchmark of task 010 that runs such a block in a
  loop is the evidence for that question.

Rules the implementation follows on hot paths: runtime functions are
locals of the module, and the generated chunk binds the ones it calls to
locals; numeric `for` loops, not `pairs`, over runtime tables; no
`debug.*`, `coroutine.running` or `select("#", …)` on a path that runs per
call or per block entry (the line number for a tombstone's message is a
constant the emitter passes, not `debug.getinfo`); one state record per
object, its fields fixed so LuaJIT keeps the table shape stable.

What stays deliberately simple, because it is not on a hot path: error
messages, `lifetime.format`, compaction, and the program-end sweep.
