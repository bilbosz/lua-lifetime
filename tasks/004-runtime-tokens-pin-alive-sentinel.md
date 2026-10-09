---
id: 004
title: Runtime: `lifetime.token`, `lifetime.pin`, `lifetime.alive`, reachable-only destructors via `newproxy`, `collectgarbage`
status: in-progress
depends: [002]
branch: task/004-runtime-tokens-pin-alive-sentinel
pr:
commits:
review:
---

## Goal

The `reachable` term means something: an anchored or registered object
that nothing refers to is found by the collector and its cascade runs from
the `newproxy(true)` sentinel's finalizer. `lifetime.token`,
`lifetime.pin`, `lifetime.alive` and `lifetime.reachable` exist and
behave as specified.

## Spec

- `docs/02-semantics.md`, "The implicit `reachable` term and
  `lifetime.pin`": `@ a` means `@ (a, reachable)`; `pin` strips the term;
  the mixing rule; the errors of `pin`.
- `docs/02-semantics.md`, "Tokens: `lifetime.token`": `lifetime.token([name])`
  returns a fresh token on the default lifetime; identity, no fields,
  metatable `"token"`, `tostring` is `token NAME` or `token: 0x…`; an
  anchor and a dependent; the name must be a string.
- `docs/02-semantics.md`, "Tombstones and `lifetime.alive`": `alive` is
  `true` for alive and dying, `false` for tombstones, `nil`, `false`;
  argument error for a value.
- `docs/02-semantics.md`, "`__destroy` and reasons", rule 7: which objects
  the runtime can notify; `x @ lifetime.reachable` registers.
- `docs/02-semantics.md`, "Reachability is the collector's": after
  `collectgarbage("collect")` every object unreachable before the call
  has had its cascade run with reason `"unreachable"`; newest first
  within one collection; weak entries clear one collection later.
- `docs/03-runtime.md`, "The sentinel": the proxy's own metatable holds
  the owner; which objects carry a sentinel; the finalizer skips an object
  already dead.
- `docs/02-semantics.md`, "Errors in destructors and `destroyerror`", and
  `docs/03-runtime.md`, "The sentinel": the finalizer runs the cascade in
  protected mode and routes every error, the first included, to
  `destroyerror` (decided: `docs/05-decisions.md`, "Errors in
  finalizer-run destructors go to `destroyerror`").
- `docs/02-semantics.md`, "The `lifetime` table": a lifetime value is an
  immutable snapshot; `@` on a value mentioning a dead anchor raises
  `attempt to anchor to a dead table` (decided: `docs/05-decisions.md`,
  "Lifetime values are immutable snapshots").

- `tasks/003-runtime-scopes-hooks.md`, review round 1, carried into this
  task: F1, `lifetime.exit(nil, …)` on an empty stack must raise before
  it pops (move the pop after the `rec.deps` read); F2, a test of
  nested-coroutine stack swapping (main, A, B, each with a record and a
  yield, B raising on its second resume: `b1` dies inside A's `resume`,
  `a1` at A's exit, `m1` at main's); task 003's test case 7 (a collected
  suspended coroutine's records die through their sentinels, innermost
  first) now that the sentinel exists; the eleven cases in
  `tests/test-runtime.lua` (lines 359 to 710) that hold no reference to
  dependents with the term must hold them (rule 6).
- `docs/05-decisions.md`, "A hook anchored to `lifetime.reachable` alone
  runs when collected": such a hook carries the sentinel and runs with
  `"unreachable"`; `lifetime.format` renders its formula as `reachable`.
- `docs/03-runtime.md`, "The state of an object" (as implemented): the
  strong table is `strong`; pinned dependents already route there
  (task 003), so `lifetime.pin` only has to produce a formula without the
  term.
- Left for a decision, not required: a plain `setmetatable` for an
  unprotected tombstone takes LuaJIT's one-object scope loop from about
  470 to 355 ns and costs 3 to 7% on Lua 5.1's destroy-heavy benchmarks
  (task 003's handoff); measure and report, do not decide alone.

## Acceptance criteria

- `lifetime.attach` adds the `reachable` term unless every anchor is a
  pinned value; `lifetime.pin(a, b)` returns a value without the term;
  `lifetime.pin()` and `lifetime.pin(lifetime.reachable)` raise the
  spec's errors; `lifetime.format` shows the term.
- A table with the term and a `__destroy`, dependents or hooks carries a
  sentinel; a pinned object and a hook do not (checked through the state
  record in tests, not through a public API).
- `collectgarbage("collect")` after dropping the last reference to such an
  object runs its cascade with reason `"unreachable"`, dependents
  included, before the call returns.
- Two unreferenced objects in one collection are finalized newest first;
  the older one's walk skips the younger one if it was its dependent.
- `x @ lifetime.reachable` on a plain table with `__destroy` registers it;
  without it, the same table is collected silently.
- `lifetime.token([name])` creates a token on the default lifetime:
  `getmetatable(t) == "token"`, `tostring(t) == "token " .. name` with a
  name and `token: 0x…` without, `lifetime.token(5)` raises the argument
  error, indexing raises `attempt to index a token value`, it can be
  anchored with `attach` and be an anchor, and it carries a sentinel under
  the same rule as a table.
- `lifetime.alive` behaves per the spec table.
- `make test` green under both interpreters; `make lint` clean.

## Test cases

1. `local x = setmetatable({}, {__destroy = log}) @ a` (via `attach`);
   `x = nil`; `collectgarbage("collect")`: log `x (unreachable)`;
   `lifetime.dependents(a)` is empty; `a` is still alive.
2. Pinned: the same with `lifetime.pin(a)`; after the collect the log is
   empty; `destroy(a)` logs `a, x (anchor)`.
3. Subtree as a cycle: `parent` registered with `@ lifetime.reachable`,
   `child @ parent` with `child.parent = parent`; drop `parent`;
   collect: log `parent (unreachable), child (anchor)` in that order.
4. Newest first: `a` then `b` both registered, unrelated, both dropped;
   one collect logs `b, a`.
5. Weak table: `w = setmetatable({}, {__mode = "k"})`, `w[x] = true`;
   drop `x`; after one collect `next(w)` may still be `x`; after two it
   is `nil`. The test asserts the second, and documents the first.
6. Token: `period = attach(lifetime.token("period"), false, session)`,
   `menu @ period`, hook on `period`; `destroy(period)` logs `hook, menu` (reverse
   attachment); `destroy(session)` afterwards does not mention `period`.
7. `alive`: `true` before `destroy`, `true` inside the body (checked from
   `__destroy`), `false` after; `alive(nil) == false`; `alive(5)` raises.
8. Metatable created in the same statement as its instance
   (`setmetatable({}, {__destroy = …})`, dropped): the destructor still
   runs under lua-lifetime, since the sentinel's finalizer resurrects the
   metatable too. Record the observed behaviour; it is the opposite of the
   `xd` inline-metatable trap and worth pinning.

The sentence most likely to be misread: "every object that was unreachable
before the call has had its cascade run" (not "will have, eventually").
Case 1 pins it by checking the log before the next statement.

## Performance

Hot paths: the sentinel (one `newproxy` per object that needs one) and
`lifetime.alive`. Benchmarks: anchoring `n` objects with the `reachable`
term and a `__destroy` against the same objects pinned (no proxy); a
`collectgarbage("collect")` over `n` unreachable anchored objects. Must
stay free: a pinned object and a hook get no proxy (assert through the
state record).

## Out of scope

- Syntax: tasks 005, 006.
- `exit` reason and the exit flag: task 007.
- Program-end behaviour under an embedding host (open question).

## Spec issues found

Found by the implementer, round 1. None changes the semantics; each says
what the code does and why, for the reviewer and the human to decide.

1. **Test case 3 contradicts the acceptance criterion and 02.** Case 3
   expects a collected subtree (`parent @ lifetime.reachable`, `child @
   parent`, `child.parent = parent`, both `__destroy`) to log `parent
   (unreachable), child (anchor)`. But `child` has the term and a
   `__destroy`, so by 03, "The sentinel", it carries a sentinel of its
   own, made after `parent`'s (the `@` that made it need one came later);
   the host finalizes newest first, so `child`'s finalizer runs first.
   02, "Reachability is the collector's", says exactly that ("objects are
   finalized newest first by creation ..., each taking its whole subtree
   in cascade order; an object already destroyed in an earlier walk is
   skipped"), and so does this task's acceptance criterion ("the older
   one's walk skips the younger one if it was its dependent"). Implemented
   (02 and the criterion): the log is `child (unreachable), parent
   (unreachable)`; the test "case 3: ..." in `tests/test-sentinel.lua`
   pins it with a comment pointing here. The consequence worth a human
   look: for a subtree the collector finds, a dependent's `__destroy` runs
   **before** its owner's, the reverse of "Cascading death" ("my
   dependents are still here and die right after me"), and the owner's
   body sees that dependent as a tombstone. 02's "A subtree nobody
   outside holds ... dies as a whole when the collector finds its root"
   reads as if case 3's order were meant. The alternative is
   implementable without a side table: a finalizer whose object has an
   anchor that is itself pending finalization in the same collection (the
   anchor's proxy has left the weak `armed` list while its owner is still
   set) does nothing and lets the anchor's walk take the object with
   `"anchor"`; that gives case 3's order and keeps the owner-first rule
   for collected subtrees, and changes the meaning of "newest first" to
   "newest root first". Not done: it is a choice between two readings of
   02, so it is the human's. Pinned dependents and hooks carry no
   sentinel, so a subtree of those already dies root first (test "the
   cascade takes the dependents with reason anchor, at collector").
2. **The exit flag's name.** 03, "Program end", and 04, "The command",
   say `lifetime run` sets "an exit flag"; nothing names it, and 06 leaves
   the embedding host's spelling open. Implemented:
   `lifetime.set_exiting(flag)`, a function on the runtime table (task
   007 calls it). 03 could name it.
3. **`lifetime.alive` of a lifetime value or the `lifetime.scope`
   marker.** 02 says `alive` is `true` for an object alive or dying,
   `false` for a tombstone, `nil` or `false`, and an argument error for a
   value that is not an object, while `destroy`, `of` and `format` refuse
   a lifetime value and the marker with `object expected, got lifetime`
   (or `lifetime.scope`). Implemented: `alive` reads any table without a
   tombstone as alive, so both give `true`, with no extra test on the hot
   path. If they should raise, `alive` needs one more branch on tables
   without a state record.
4. **Sentinel reuse.** 03 says the proxy is "allocated lazily: on the
   first `@` that makes the object need one ... and never again for the
   same object", and "Performance" counts "one `newproxy(true)` per
   table". The runtime keeps the proxy of an owner that died by a cascade
   for a later owner when that keeps the finalization order (the proxy was
   in the last slot handed out; `armed`, `kept` in `lifetime/init.lua`),
   so a loop that owns objects allocates no proxy after its first
   iteration. Never twice for the same object still holds, and the order
   the host finalizes in is the order of the `@`s, as for fresh proxies;
   a proxy whose finalizer is already pending is never kept (test "a
   proxy whose finalizer is pending is not handed to another owner"). The
   runtime holds the kept proxies (each refers to nothing but itself):
   their number is bounded by the most sentinels ever disarmed newest
   first. Without the reuse a fresh `newproxy` per object made
   `attach`+`destroy` of an object with a sentinel about 600 ns dearer on
   Lua 5.1 and 400 ns on LuaJIT. 03 could mention it.
5. **More dependents with the term held by nobody.** Besides the eleven
   cases of `tests/test-runtime.lua` that task 003's review named, twenty
   statements in `tests/test-scopes.lua` attached a logging dependent to a
   scope record without keeping it, inside frames that an error unwinds.
   With the sentinel any of them could die `"unreachable"` before the
   exit. They are held now (`hold` in that file; CLAUDE.md, rule 6).

## Review log

- Implementer, round 1 (resumed after a container restart). The
  previous implementer's `31f8b03` and `2ae3266` carried the runtime
  (sentinel, token, pin, alive, the exit flag `lifetime.set_exiting`,
  F1) but no tests of it; `0a89c29` (its uncommitted work, committed by
  the orchestrator) generalised the one spare proxy to a stack of spares
  ordered by a weak `armed` list. It was coherent and complete, and was
  kept, then reworked for speed: kept proxies stay in their slots
  (`kept[slot]`), so arming and disarming write less, and holes are
  handled only off the common path. Tests for the whole task are new in
  `tests/test-sentinel.lua`; F2 and task 003's case 7 are there too.
- Implementer, round 1, robustness: the unit suite passes with an eager
  collector (`collectgarbage("setpause", 1 .. 10)`, `setstepmul` 200 to
  1000) under both interpreters, apart from two task 003 tests that
  count memory or a compaction range under LuaJIT ("enter in a loop
  allocates the records and nothing else", "hooks are compacted with the
  other dependents") and fail there now and then; under the same
  settings master's `tests/test-runtime.lua` fails three to seven of the
  cases whose dependents nothing held (no sentinel there: the dependent
  simply vanishes from its anchor's list).
- Implementer, round 1, performance: `make bench BASE=master`, four
  invocations, the last three on the final runtime (`ec619eb`). Marks:
  run 1 (`6199bf1`): `runtime/attach-destroy-100` (LuaJIT, 1.156/1.179)
  and `scope/loop-one-object` (Lua 5.1, 1.112/1.108); run 2: none; run
  3: `runtime/attach-destroy-100` (LuaJIT, 1.148/1.101) and
  `scope/pcall-empty` (LuaJIT, 26 vs 30 ns; this task does not touch
  `pcall`); run 4: `runtime/attach-destroy-100` (LuaJIT, 1.160/1.205)
  and `runtime/cascade-tree` (LuaJIT, 1.147/1.126). Lua 5.1 is clean in
  runs 2 to 4 (`runtime/attach-destroy-100` 1.08 to 1.09,
  `runtime/cascade-tree` 1.04 to 1.08, `scope/loop-one-object` 1.03 to
  1.09). So `runtime/attach-destroy-100` under LuaJIT is marked in two
  consecutive invocations (3 and 4): a finding by bench/README.md's rule,
  for the orchestrator to decide. Every object of
  `runtime/attach-destroy-100` and `runtime/cascade-tree` has a
  `__destroy` and the term, so it now needs a sentinel
  (docs/03-runtime.md, "Performance", "Forced, and measured"): arming
  and disarming one costs about 40 to 60 ns per object on LuaJIT (master
  about 350 ns per object for the whole attach-and-destroy) and about
  130 to 170 ns on Lua 5.1 (master about 2100 ns). Without the
  bookkeeping the runtime matches master (measured with the arming
  removed). In-process, `sentinel/anchor-100` (the term against the same
  objects pinned) reads 0.98 to 0.99 on Lua 5.1 and 1.06 to 1.09 on
  LuaJIT.
- Implementer, round 1, the `setmetatable` measurement (not decided):
  tombstoning with `setmetatable` when the object's metatable is not
  protected (`rawget(mt, "__metatable") == nil`), `debug.setmetatable`
  otherwise, against the final runtime, `make bench BASE=HEAD` on the
  runtime, scope and sentinel files: LuaJIT `runtime/attach-destroy-100`
  0.959, `runtime/cascade-tree` 0.977, `scope/loop-one-object` 0.958,
  `scope/hook-on-scope` 0.972, `sentinel/anchor-100` 0.971; Lua 5.1
  `runtime/attach-destroy-100` 1.056, `runtime/cascade-tree` 1.009,
  `scope/loop-one-object` 1.009, `sentinel/anchor-100` 1.038. The extra
  `rawget` is a C call on Lua 5.1; `debug.setmetatable` is stitched, not
  compiled, on LuaJIT. Reverted.
