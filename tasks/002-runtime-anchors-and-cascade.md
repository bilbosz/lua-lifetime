---
id: 002
title: Runtime: anchors, dependents inside the anchor, `destroy`, cascade order, tombstones, `destroyerror`
status: review
depends: [001, 010]
branch: task/002-runtime-anchors-and-cascade
pr: https://github.com/bilbosz/lua-lifetime/pull/16
commits:
review: APPROVE (round 1)
---

## Goal

`require("lifetime")` can anchor an object to one or more table anchors,
destroy an object with the full two-phase cascade in the order of decision
10, tombstone what died, and route destructor errors. No syntax yet: tests
call `lifetime.attach`, `lifetime.destroy`, `lifetime.discard`,
`lifetime.of`, `lifetime.dependents` and `lifetime.format` directly. No
`reachable` term handling beyond recording it (task 004), no scopes, hooks
or tokens (tasks 003, 004).

## Spec

- `docs/02-semantics.md`, "Acquiring a lifetime: the `@` operator",
  steps 1 to 4 and the error texts; "No moves during destruction".
- `docs/02-semantics.md`, "Explicit destruction: `destroy` and `discard`":
  "`destroy(nil)` is a no-op. `destroy` on a dead or dying object is a
  no-op".
- `docs/02-semantics.md`, "Cascading death: the order of decision 10":
  decide then destroy; "its own destructor body runs … with every
  dependent still alive and usable; its dependents and hooks are destroyed,
  most recently attached first … it is emptied and tombstoned"; the
  worked example (`c, d, a, hook, b` without the hook here).
- `docs/02-semantics.md`, "`__destroy` and reasons", rules 1 to 5 and 7.
- `docs/02-semantics.md`, "Tombstones and `lifetime.alive`": the dead
  metatable, the message, what does not raise.
- `docs/02-semantics.md`, "Errors in destructors and `destroyerror`".
- `docs/02-semantics.md`, "The `lifetime` table": `of`, `dependents`,
  `format`; lifetime values as tables with the metatable `"lifetime"`.
- `docs/03-runtime.md`, "The state of an object", "Attachment",
  "The cascade", "The tombstone".
- `CLAUDE.md`, rule 6 and "Technical decisions".

## Acceptance criteria

- `lifetime.attach(obj, pin, a1, …, an)` validates `obj` and each anchor
  with the error texts of the spec, replaces the formula, unlinks from old
  anchors and links at the end of each new anchor's list, and returns
  `obj`. The anchors are kept in the dependent's state record strongly;
  the anchor's `dependents` table is weak-valued and keyed by sequence
  number.
- `lifetime.destroy(obj)` runs the cascade: decide (every dependent of a
  dying anchor dies, closed before any body runs), then for each object
  body → dependents newest first → tombstone. `destroy(nil)`, `destroy` on
  a dead or dying object are no-ops; `destroy(5)` raises the argument
  error.
- `lifetime.discard(obj)` skips `obj`'s own body only.
- `__destroy` is read from `getmetatable(obj)` (or `debug.getmetatable`)
  at the moment of death and called as `__destroy(obj, reason)` with
  `"destroy"` for the root and `"anchor"` for dependents.
- Inside a body, `attach` on an object that predates the phase and has an
  explicit formula raises `attempt to move an anchored table during
  destruction`; on an object created during the phase it works.
- A tombstone is empty, has `getmetatable(dead) == "dead"`, raises
  `attempt to index a dead table (<name>, died at <where>, <reason>)` on
  index, with `assign to` and `call` as the other verbs; `rawget`, `next`,
  `#`, `==` and `tostring` (`dead <name>`) do not raise. `<name>` is the
  `tostring` of the object before death (so a `__tostring` names it);
  `<where>` is `chunk:line` of the `destroy` call.
- The first error of a cascade is held and re-raised after the cascade;
  later errors go to `destroyerror(obj, err)` read raw from `_G`; the
  default handler writes `destroyerror: <message>` and a traceback to
  stderr; a raising handler produces the `error in destroyerror` line.
- `lifetime.of(obj)` returns a value with `getmetatable(v) == "lifetime"`;
  `lifetime.format(lifetime.of(obj))` renders `(a, reachable)` for an
  object attached to `a`, `reachable` for a default-lifetime object seen by
  the runtime, `a` for a pinned one. `lifetime.dependents(a)` returns live
  dependents in attachment order.
- `make test` is green under both interpreters; `make lint` is clean.

## Test cases

Log every destructor call into a table and compare whole sequences.

1. The worked example without the hook: `a`, `b @ a`, `c`, `d @ (a, c)`,
   then `destroy(c)`: log `c, d`; then `destroy(a)`: log `a, b` (`d` is
   already dead and skipped). Tombstones: `lifetime.alive` is task 004, so
   check `getmetatable(d) == "dead"` and that `d.x` raises with `d`'s name.
2. Body before dependents: `conn` with `__destroy` printing `self.buf.n`;
   `buf = {n = 1} @ conn`; `destroy(conn)` logs `conn sees 1`, then
   `buf`. After the cascade `conn.buf` raises the dead-table error.
3. `destroy` inside a body: `A.__destroy` calls `destroy(self.child)` by
   hand; the runtime's later pass skips the child; the log has the child
   once, before `A`'s remaining dependents.
4. Error rule: three dependents of `root` whose bodies raise `"one"`,
   `"two"`, `"three"` in attachment order; `destroy(root)` raises `"three"`
   (newest first runs first) after all three ran, and `destroyerror`
   received `"two"` then `"one"`, in that order, with the objects.
5. Moves during destruction: inside `A.__destroy`, `attach(self.b, false,
   other)` raises the move error; `attach({}, false, other)` works.
6. Weakness: a dependent kept only by its anchor's list is collected by
   `collectgarbage("collect")` (observe through a weak-keyed set the test
   holds); the anchor's `lifetime.dependents` no longer lists it.
   (Its destructor is task 004's concern; here the test only checks that
   the runtime did not keep it alive, rule 6.)

The sentence most likely to be misread: "its own destructor body runs …
with every dependent still alive and usable" against the `xd` order that
dependents die first. Case 2 pins it, and case 1's `c` before `d`.

## Performance

Hot paths: `attach` (first anchor and move), the cascade, the tombstone,
`lifetime.dependents`. Benchmarks (`bench/`, task 010's harness): attach
and destroy of `n` dependents on one anchor against a hand-written table
with an explicit `close` loop; a move between two anchors; a cascade over
a three-level tree. Must stay free: a table never anchored gets no state
record (assert it in a test). The dependents walk is a numeric loop over
the sequence range with compaction, no sort (`docs/03-runtime.md`, "The
state of an object").

## Out of scope

- The `reachable` term's effect (the sentinel, finalizers): task 004.
- Scopes, hooks: task 003. Tokens and `pin`: task 004.
- Non-table dependents (functions, coroutines, userdata): a follow-up once
  `docs/06-open-questions.md`, "Non-table anchors" is settled.
- Base-class destructors (open question).

## Spec issues found

Found by the implementer, round 1. None changes the semantics; each says
what the code does and why, for the reviewer and the human to decide.

1. **`destroy` on a dying object inside a body.** `docs/02-semantics.md`,
   "Explicit destruction", says "`destroy` on a dead or dying object is a
   no-op, so a destructor body may destroy its own dependents by hand,
   early, and the runtime's later pass skips them". With decide-then-destroy
   ("Cascading death", step 1) every dependent is already *dying* when the
   anchor's body runs (the Vocabulary's definition), so read literally the
   by-hand `destroy` would do nothing and nothing would happen early.
   Test case 3 of this task and "What a destructor may assume" ("It may
   also see dependents it destroyed by hand already torn down") need the
   early destruction. Implemented: `destroy`/`discard` is a no-op on a dead
   object and on a dying one whose destruction has begun; a dependent
   decided dying and not yet reached is destroyed now, as a cascade of its
   own (reason `"destroy"`, `<where>` the by-hand call), with the subtree
   the running cascade decided. Suggested wording: "`destroy` on a dead
   object, or on one whose destruction has already begun, is a no-op".
2. **A tombstone is not empty under `next`.** 02, "Tombstones", says
   `rawget`, `next`, `pairs`, `#` "see an empty table"; `docs/03-runtime.md`,
   "The tombstone" and "The cascade", keep the state record, reduced, in
   the tombstone ("record `reason` and `where`"), and the private-key
   decision makes that field visible to `next`. Implemented as 03 says:
   every user field is cleared, the record stays under the private key, so
   `next(dead)` returns that key and `lifetime.is_state` skips it. 02 could
   say "an empty table apart from the state record".
3. **`<where>` for a bare table.** 03, "The cascade", reads
   `debug.getinfo(2, "Sl")` "only when the object it destroys has
   dependents or a destructor"; 02, "Tombstones", puts `<where>` in every
   tombstone's message, including a `destroy`ed table with neither.
   Implemented as 02: `destroy`/`discard` of a live object always read the
   caller's position (once per call, not per object).
4. **Pinned dependents and the weak list.** 02, "Summary": `@
   lifetime.pin(a)` is kept alive by `a`. 03 makes `dependents`
   weak-valued and only `hooks` strong, and says nothing about where the
   strong reference to a pinned dependent lives. Here `attach(x, true, a)`
   records a formula without the term but links `x` weakly like any
   dependent, so an unreferenced pinned table is collected. Task 004
   (`lifetime.pin`) has to decide where pinned dependents are held.
5. **Two messages for moving a dying object.** 02, step 3: "If `e` is
   dying, error: `attempt to move a dying table`"; "No moves during
   destruction": moving an older anchored object, "the dying object
   included, is `attempt to move an anchored table during destruction`".
   Implemented step 3 first: any dying object gives `attempt to move a
   dying table`; an older, explicitly anchored live object during a phase
   gives the destruction message (tests cover both).
6. **Texts the spec does not give**, chosen to follow its patterns:
   `attach` on a dead object and `lifetime.of`/`lifetime.format` of one
   raise the tombstone's own message with the verb `index` ("the dead
   metatable raises first"); `attach` of a lifetime value is `attempt to
   anchor a lifetime value`; `destroy`/`discard`/`lifetime.of` of a
   lifetime value is `bad argument #1 to '…' (object expected, got
   lifetime)`; `lifetime.format(5)` is `bad argument #1 to
   'lifetime.format' (lifetime expected, got number)`; `attach(x, false)`
   with no anchor is `bad argument #3 to 'lifetime.attach' (anchor
   expected, got no value)`.
7. **Smaller choices.** No global `destroyerror` is installed: when the
   global is `nil` the default handler runs; "not callable" applies to any
   other non-callable value. A `__tostring` that raises while the name is
   captured falls back to the raw `table: 0x…` name. The tombstone of a
   `discard`ed root records reason `"destroy"`. `==` on lifetime values
   compares the term and the set of anchors, order ignored (a
   conjunction). `<name>` is captured in the decide step, as 03 says
   ("captured when the object starts dying"), which 02's "just before the
   object died" reads loosely.
8. **Non-table dependents** (out of scope here): `attach`, `destroy`,
   `discard` and `lifetime.of` on a function, coroutine or userdata raise
   `lifetime: … is not implemented yet` rather than guessing.

## Review log

### Round 1: APPROVE

Suite on `07cf1a8`, judged against the spec at `be436b4`: unit 125/125 under lua5.1 and luajit, conformance 5/5 under both, lint clean (25 files). `make bench BASE=master`: no `SLOWER` mark; plain-path ratios at 1.0 within noise. Traced by hand: case 2 (body sees dependents alive), diamond order `root, q, r, p`, by-hand `destroy` of a decided sibling with a subtree, a second anchor destroyed from a live root; a randomized differential of 3 seeds x 4000 attach/move/destroy operations against a reference model under both interpreters: every log and every `lifetime.dependents` order matched. Rule 6 confirmed: the runtime's only strong references to user objects are a dependent's record to its anchors and a lifetime value to its anchors. Technical decisions confirmed line by line; `select("#", ...)` in `attach` measured as free; nothing `debug.*` on any `attach` path; the cascade still compiles under LuaJIT.

- F1 (non-blocking): `docs/03` lists `seq` and `lo` as record fields and names the weak table `dependents`; the code keeps `seq`, `lo`, `limit` in the anchor's weak table `deps` (behaviour identical, the better layout for an object never used as an anchor). Settled: `docs/03` is corrected by the orchestrator in the done chore; task 004 names the strong table `strong` beside `deps`.
- F2 (non-blocking): comments in `lifetime/init.lua` and items 1 to 3 of *Spec issues found* quote the superseded sentence of "Explicit destruction". Settled: items 1 to 4 below are decided by `docs/05-decisions.md` ("`destroy` by hand inside a destructor", "A tombstone keeps its state record", the `<where>` correction in that entry, "Pinned dependents are held by their anchors"); the code follows them; the comments are updated by the follow-up task that replaces the non-table stub.
- F3 (non-blocking): the `not implemented` stub positions `destroy(fn)`, `discard(fn)` and `lifetime.of(fn)` errors inside the runtime. Folded into the non-table-dependents follow-up task, which replaces the stub.
- F4 (non-blocking): `runtime/move` and `runtime/attach-first` read 3 to 4x slower in a full `make bench` than alone under luajit (process state left by the transpiler benchmarks). Follow-up harness task: each `bench-*.lua` in its own process; the handoff's `attach-first` 273 ns (1.0x) did not reproduce (2.0x alone).
- Questions for a one-line clarification some day: a repeated anchor in the list form (`x @ (a, a)`) links twice; `attach(dead, false, nil)` reports step 2 before step 3.
