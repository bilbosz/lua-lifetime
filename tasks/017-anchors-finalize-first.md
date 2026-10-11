---
id: 017
title: Runtime: keep each anchor's sentinel newer than its dependents' so a collected subtree dies in ownership order
status: in-progress
depends: []
branch: task/017-anchors-finalize-first
pr:
commits:
review:
---

## Goal

A subtree the collector finds unreachable dies as one cascade from its
root, in ownership order, whatever the order in which its objects were
registered: the root with reason `"unreachable"`, its dependents with
`"anchor"`, the owner's body before its dependents'. The runtime
achieves it by exchanging sentinel proxies at each `@` so that an
anchor's proxy is always newer than its dependents'; a cycle of anchors
ends the climb. The two examples and the trial scenario that showed the
old order show the new one.

## Spec

- `docs/02-semantics.md`, "Reachability is the collector's": "Within one
  collection, **an anchor is finalized before its dependents**, and
  objects not ordered by ownership are finalized **newest first** by
  creation"; "A subtree collected at once therefore dies as one cascade
  from its root, in ownership order: the root with reason
  `"unreachable"`, its dependents with `"anchor"`"; "Where the ownership
  graph has a cycle ... the proxies stay as they are and the host's order
  decides which of the cycle's objects is the root".
- `docs/03-runtime.md`, "The sentinel", "Anchors first": the exchange
  after every link, the climb through the anchor's anchors, scope
  records ordered the same way, the phase-counter mark that ends the
  climb on a cycle, the cost bound ("one comparison per link in the
  common case ... one exchange per ancestor whose proxy is older").
- `docs/03-runtime.md`, "The scope stack and the error path", last
  paragraph: a collected suspended coroutine's records die innermost
  first with their dependents in cascade order.
- `docs/05-decisions.md`, "Anchors are finalized before their
  dependents": the `.expected` updates ride this task's pull request.
- `docs/02-semantics.md`, "Cascading death": the order inside the one
  cascade is unchanged.
- `CLAUDE.md`, rules 2 (say in the commit why an `.expected` changes), 5
  (benchmark the hot path) and 6 (no strong reference kept).

## Acceptance criteria

- `lifetime/init.lua`: after every link that gives a dependent an anchor
  (`lifetime.attach`'s fast paths and `attach_general`, moves and the
  list form included; hooks are pinned and carry no sentinel; tokens
  with the term are ordered like tables; a scope record anchor uses its
  `sentinel` field), if the dependent carries a sentinel and an anchor's
  sentinel is older (`slot` smaller), the two records exchange their
  metatables and the metatables' `owner` fields, and the climb continues
  from that anchor through its own anchors while the proxy it now holds
  is newer than theirs. Records visited in one climb are marked with a
  fresh phase id so a cycle of anchors ends it. The exchange allocates
  nothing and runs inside the `busy` region of the operation.
- A dependent linked to an anchor that has no sentinel yet (lazily
  armed at this link) needs no exchange: the anchor's new proxy is the
  newest. The common path pays one comparison.
- The program of the demonstration, a three-level tree whose class
  registers every instance at construction, dropped and collected,
  prints `parent destroyed (unreachable), child alive: true`, `child
  destroyed (anchor), child alive: true`, `grandchild destroyed
  (anchor)` on both hosts, and the same under an eager collector.
- `examples/move.lt` and `examples/pinned_parent.lt`: comments and
  `.expected` updated to the new order (`child (anchor)` after the root);
  their rows in `docs/07-conformance.md` say so; the commit names the
  decision. No other `.expected` changes.
- `trial/treflove/run.lua`: the "collected" scenario's expected log is
  the ownership order with reasons `unreachable` for the connection and
  `anchor` below it, no `destroyerror`; `trial/treflove/README.md`'s
  finding on registration order is rewritten (registered and
  unregistered runs now agree); task 009's spec issue 1 is noted as
  settled in `tasks/009-treflove-trial.md`.
- `tests/test-sentinel.lua`: "case 3: a subtree held only by itself ..."
  and "the older one's walk skips the younger one ..." expect the new
  order; new cases below.
- `bench/bench-sentinel.lua`: a new `sentinel/register-tree` row (a tree
  of depth 3 with 10 children per node, every object registered at
  construction then linked `child @ parent`, against the same tree linked
  without prior registration) and `sentinel/anchor-100`, `runtime/
  attach-first`, `runtime/move` within the threshold of `bench/README.md`
  (`make bench BASE=master` twice, the two-run rule); the README row
  added.
- `make test` and `make lint` green under both interpreters.

## Test cases

1. Registered tree: `p = C(); c = C() @ p; g = C() @ c` with every `C()`
   doing `@ lifetime.reachable` and holding its child in a field; drop
   `p`, collect: log `p (unreachable)`, `c (anchor)`, `g (anchor)`, and
   inside `p`'s body `lifetime.alive(c)` is `true`.
2. Lazily armed parent: `p = {}` with a `__destroy`, `c = C() @ p` where
   `c` is registered first; drop both, collect: `p (unreachable)`, `c
   (anchor)` (the parent's proxy is made at the link and is newer).
3. Reverse creation: the child created and registered before the
   parent, then `child @ parent`: same order as case 1.
4. Two anchors: `x @ (a, b)` with `a` older than `b` and `x` newest; drop
   all three, collect: the first finalized is `b` or `a` by newest
   first, `x` dies `anchor` through whichever cascades first, the other
   anchor's walk skips it; `x` is never `unreachable`.
5. Cycle: `a @ b; b @ a` registered both; drop both, collect: each dies
   once, one `unreachable` and the other `anchor`; the climb terminates
   (the test must not hang, and a stack-depth assertion inside the
   destructors checks no runaway recursion).
6. Move: `c @ p1` then `c @ p2` with `p2` older than `c`; drop `p2` and
   `c`, collect: `p2 (unreachable)`, `c (anchor)`.
7. Scope record: a suspended coroutine with `x @ lifetime.scope` in a
   block, `x` registered at construction with a `__destroy`; drop the
   coroutine, collect: `x (anchor)`, not `unreachable`.
8. Unrelated objects still die newest first (existing case 4 unchanged).
9. The trial's "collected" scenario and the two examples print their new
   `.expected` on both hosts.

The sentence most likely to be misread: "objects not ordered by
ownership are finalized newest first" still holds between siblings:
among the dependents of one root the cascade order (most recently
attached first) decides, not the proxies; case 1 with three children
pins it.

## Performance

Hot path: every `@` pays one comparison; the eager-registration idiom
pays the exchanges. `sentinel/register-tree` measures the latter;
`sentinel/anchor-100`, `runtime/attach-first` and `runtime/move` guard
the former. Report absolute numbers for both hosts.

## Out of scope

- Any change to when a collection happens or to the cascade order.
- Detecting or reporting the old order.

## Spec issues found

1. **The exchange can leave the linked object older than its own
   dependents** (03, "Anchors first": "The invariant 'an anchor's proxy
   is newer than every dependent's' then holds along every ownership
   path"; it does not in this shape). The exchange gives the dependent
   the anchor's older proxy. When the dependent already has dependents
   with proxies (a subtree moved under an older anchor; a class whose
   constructor attaches children `@ self` before the instance is
   attached to its owner, Treflove's `Session(connection) @ connection`
   with an older registered connection), those can end newer than it.
   If the whole tree is collected the root is still the newest and the
   order is right; if only the subtree is (the owner lives), the
   subtree's dependents are finalized first, `"unreachable"`, against
   02's "an anchor is finalized before its dependents". Reproduction
   (registered = `@ lifetime.reachable` with a `__destroy`): `p =
   reg(); c = reg(); c.g = reg() @ c; c @ p`, keep `p`, drop `c`,
   collect: `g (unreachable), c (unreachable)`; 02 wants `c
   (unreachable), g (anchor)`. Fixing it needs the symmetric step, a
   descent: after the climb, while the linked object's proxy is older
   than its newest dependent's, exchange the two and continue from that
   dependent (and re-climb from the object, whose proxy grew). On an
   acyclic graph every exchange of an inverted ancestor-descendant pair
   strictly lowers the number of inverted pairs, so it terminates; on a
   cycle it needs marks like the climb's. It costs a scan of a
   dependents list per level, which 03's cost bound does not include.
   Not implemented: the mechanism and its cost are the design's
   (03), and the task specifies the climb. For the human.
   **Implemented in round 2** (the orchestrator's ruling: 02 and 03
   promise the order on every path). `sift` in `lifetime/init.lua`:
   while a dependent below the record that holds the old proxy holds a
   newer one, the newest of them (looking through transparent
   dependents) exchanges with it and the descent goes on from it.
   `reorder` runs the climb, then the descent when the climb changed the
   object's proxy and the object has dependents, then the climb again
   when the descent gave the object a newer proxy, until neither changes
   it. Why it ends with the order restored, on an acyclic graph: an
   exchange across an out-of-order anchor-dependent pair `(u, v)` puts
   that pair in order and changes no other pair's order unfavourably
   (for a record `w` above `v` only, `v`'s proxy fell; for `w` below `u`
   only, `u`'s rose; for `w` between them the two pairs `(u, w)` and
   `(w, v)` lose as many inversions as they gain or more), so the number
   of out-of-order pairs falls with every exchange and the walks stop
   with none left on the paths they walked. Every record the descent
   passes takes the newest proxy below it, older than its own was, so
   its other anchors stay newer; every anchor the climb exchanges with
   takes a newer proxy than its own was, so its other dependents stay
   older; only the linked object can end out of order with an edge the
   walk in the other direction did not look at, which is why `reorder`
   alternates. The orchestrator's sketch skipped the second climb; it is
   needed when the object has more than one new anchor: with `a`, `b`,
   `m` registered in that order and `d @ m`, `m @ (a, b)` climbs past
   `a` only, the descent gives `m` the proxy of `d`, which is newer than
   `b`'s, and only a second climb puts `b` above `m` (test "a list form
   with a dependent below"). The proxy the descent gives back falls each
   round (each dependent gives one up once), so a round where it does
   not, which only a cycle through the object allows, ends the loop; on
   cycles the climb's marks, a fresh mark on every record the descent
   passes, and `deps.path` on transparent records end the walks.
2. **A pinned anchor between two proxies is not climbed through.** A
   record without a proxy is not compared (the acceptance criteria:
   "if the dependent carries a sentinel and an anchor's sentinel is
   older"), and the climb only continues from an anchor it exchanged
   with, so `b = reg(); a = obj @ lifetime.pin(b); x = reg() @ a`,
   all dropped, collects `x (unreachable), b (unreachable), a
   (anchor)`; 02 wants `b (unreachable), a (anchor), x (anchor)`.
   Climbing through proxy-less anchors (comparing the dependent's proxy
   with the pinned anchor's anchors') would fix it at the price of a
   walk through every pinned ancestor on each link. Not implemented,
   for the same reason as item 1.
   **Implemented in round 2.** A record without a proxy (pinned, a
   hook, a table with the term and nothing to run, a main-thread scope
   record) is transparent: the climb compares the dependent with its
   anchors, transitively (`climb_through`), the descent looks through it
   to its dependents (`newest_below`), and an object a move leaves
   without a proxy reorders the dependents below it (`reorder_below`),
   whose anchors for the order are now its new ones. The reproduction
   now collects `b (unreachable), a (anchor), x (anchor)`.
3. **`examples/coroutines.lt` changes too.** The decision's
   consequences name `move.lt` and `pinned_parent.lt` only, and the
   dispatch said "No other `.expected` changes", but 03, "The scope
   stack and the error path", last paragraph (the records' proxies are
   kept newer than those of the objects they anchor), and this task's
   test case 7 make part 2 of `coroutines.lt` print `close b step 2
   (anchor)` and `close b outer (anchor)` where it printed
   `"unreachable"`: its `.expected`, comments and row in 07 are updated
   in commit `00a478d`, whose message says the spec made the old
   expectation wrong. The new output is what `xd/examples/coroutines.xd`
   printed. Likewise a third unit test flipped beside the two the task
   names: task 003's case 7 in `tests/test-sentinel.lua` (a collected
   coroutine's record takes `x` with `"anchor"`), which is this task's
   case 7.
4. **The pool's handling of proxies disarmed below the last slot
   changed** (`lifetime/init.lua`, "Sentinels"). Anchors first makes a
   cascade disarm its older proxies first; the old pool dropped every
   proxy disarmed below the last slot, so each destroy of an anchored
   tree lost its dependents' proxies and the next attaches allocated
   (`sentinel/anchor-100` 2.2 times `master` on LuaJIT). Such a proxy
   now stays kept in its slot and is reused once the slots above it are
   disarmed; the kept proxies close over the holes the collector
   leaves. This keeps 03's wording ("a disarmed proxy is kept by the
   runtime in its slot and reused for a later owner, never twice for the
   same object and never while its finalizer is pending"), but three
   unit tests that pinned which kept proxy the next owner takes
   (`tests/test-sentinel.lua`, the reuse cases) now expect the new
   slots; the final finalization order they assert is unchanged.
5. **Where the climb's mark lives.** 03 says "the climb marks the
   records it has visited with the phase counter". The record's
   `phase_id` is the phase guard's ("No moves during destruction": an
   object created in the running phase may move), so a climb that
   rewrote it would change which moves are refused. The mark is
   `deps.mark`, a field of the record's anchor side (the `deps` table
   that 03, "The state of an object", "As implemented", already keeps
   `seq`, `lo` and `limit` in), set only on records the climb goes on
   above; an id comes from `phase_counter` only when a climb goes above
   an anchor.
6. **03's cost bound is optimistic for the commonest shape, and has no
   numbers yet.** "Cost: one comparison per link in the common case (a
   lazily armed anchor's proxy is made at its first link and is already
   the newer one)" holds for an anchor's first link only. A dependent
   armed at its link (a fresh object with a `__destroy`) gets the newest
   proxy there is, so every later link of such an object to an anchor
   already armed is an exchange, and one more per armed ancestor: 100
   children of one anchor pay 99 exchanges (`sentinel/anchor-100`), and
   a tree built top down pays one per level per node
   (`runtime/cascade-tree`). The spec forces it ("an anchor is finalized
   before its dependents" with "newest first by creation" among the
   rest: the new object's proxy cannot be older than an unrelated
   object made before it). Measured (`make bench BASE=master`, two
   invocations, pairings): on LuaJIT every row is within the threshold;
   on Lua 5.1 `runtime/cascade-tree` reads 1.18 to 1.27 (marked in
   both, a finding by the two-run rule, about 300 against 250 us per
   tree of 111), `sentinel/anchor-100` 1.02 to 1.19 (marked in one
   invocation of two, about 240 against 215 us), and the new
   `sentinel/register-tree` 1.15 to 1.22 against a base that does not
   exchange. 03, "The sentinel", refers to "Performance" for the
   measurement, which a spec commit should add; the handoff of this task
   has the numbers. Round 2 (the descent and transparent anchors, two
   more invocations): LuaJIT unchanged, within the threshold everywhere;
   Lua 5.1 `runtime/cascade-tree` 1.20 to 1.26 in one invocation
   (marked) and 1.09 to 1.11 in the other, `sentinel/anchor-100` 1.02 to
   1.16 (not marked), `sentinel/register-tree` 1.14 to 1.28 (marked in
   both, against a base that does not exchange). Per link of the tree
   benchmark (110 links, every one an exchange and most a climb of two
   levels), the exchanges cost about 230 to 510 ns on Lua 5.1 and 7 to
   25 ns on LuaJIT; registration with its exchanges, against the same
   tree without (`sentinel/register-tree`, in process), 1.69 to 1.75 on
   Lua 5.1 and 1.05 to 1.08 on LuaJIT.

## Review log

### Round 2 (implementer)

Orchestrator rulings on round 1 (`43b5053`): the `coroutines.lt`
change, the third flipped test, the pool change and `deps.mark` are
accepted; spec issues 1 and 2 are to be implemented in this task. Done
in `cfa0c47`: the descent (`sift`, `reorder`) and transparent anchors
(`climb_through`, `newest_below`, `reorder_below`), with a second suite
of tests in `tests/test-sentinel.lua` (the reproductions of items 1 and
2, a chain of three, several dependents, Treflove's session dropped
while its connection lives, a pinned dependent on the descent path, an
object pinned by a move, a list form that needs the second climb, a
cycle of pinned anchors, random graphs in random order with moves,
pins and lists checked after every operation). Case 5's two-cycle now
leaves the other proxy order: the descent exchanges back, and on a
cycle the host picks the root.
