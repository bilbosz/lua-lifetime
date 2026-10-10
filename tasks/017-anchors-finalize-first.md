---
id: 017
title: Runtime: keep each anchor's sentinel newer than its dependents' so a collected subtree dies in ownership order
status: todo
depends: []
branch:
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

## Review log
