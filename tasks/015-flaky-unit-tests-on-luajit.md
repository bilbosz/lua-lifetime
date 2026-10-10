---
id: 015
title: Make the unit tests that fail now and then under LuaJIT deterministic without weakening what they assert
status: done
depends: [012]
branch: task/015-flaky-unit-tests
pr: https://github.com/bilbosz/lua-lifetime/pull/39
commits: 4cfd58be3d1c9434245771f60da8d8f59c9a0dcb
review: APPROVE (round 1)
---

## Goal

`luajit tests/run.lua unit` passes 100 of 100 consecutive runs with the
default collector and 20 of 20 with an eager one (`collectgarbage
("setpause", 10)`, `collectgarbage("setstepmul", 1000)` before loading),
with every assertion still pinning what it pinned. Three tests fail now
and then on `master` under LuaJIT only; each is fixed by removing the
host noise it measures through, never by loosening the order it asserts.

## Spec

- `CLAUDE.md`, rule 8: "If it is not green, the task is not done." A
  suite that is green nine runs in ten is not green.
- `CLAUDE.md`, rule 3: "Ownership order is the product; reachability
  timing is not ... tests pin it with `collectgarbage("collect")` and
  never with timing."
- `docs/02-semantics.md`, "Reachability is the collector's": "Within one
  collection, objects are finalized **newest first** by creation ("Host")".
- `docs/03-runtime.md`, "The sentinel": the proxy pool, a disarmed proxy
  reused by the next owner; finalization order follows the proxy, not
  the owner (the sentence the fix for test 3 must cite or correct).
- `docs/03-runtime.md`, "Performance" and `docs/05-decisions.md`, "Scopes
  unwind at the catch site": a block with a scope record allocates the
  record and nothing else (what tests 1 and 2 measure).

## Acceptance criteria

- `tests/test-scopes.lua`, "enter in a loop allocates the records and
  nothing else" (the `many == 1000 * one` assertion) and the `used == 0`
  assertion in the later scope-stack case: the measurement no longer
  includes what LuaJIT allocates on its own between the two readings
  (observed: 250.29 KB for 1000 records against 250 expected, i.e.
  about 300 bytes once, a trace or a snapshot). Fix by whatever the
  cause is, found first: warm the JIT until the count is stable before
  reading, or run the measured loop with `jit.off()` on the function and
  note the compiled cost in the benchmark instead, or take the readings
  as the minimum of several. The assertion stays an equality on the
  record's size; a tolerance band is not acceptable.
- `tests/test-sentinel.lua`, "a disarmed proxy is reused by the next
  owner": under an eager collector `y1`, `x1`, `y2` come out in another
  order (seen 1 of 60 and 2 of 20 eager runs). Find why (a collection
  between the `destroy` calls and the `attach` calls disarming or
  finalizing a pooled proxy, or the pool handing a proxy whose creation
  order differs from the one the test assumes), state it in the test,
  and make the test deterministic under the eager collector by holding
  what must be held, never by sorting the log or relaxing the expected
  order. If the finding is that the runtime's order promise ("newest
  first by creation") is broken by proxy reuse, that is a spec issue:
  record it under "Spec issues found" and stop that part.
- The same three tests pass under Lua 5.1 as before.
- `make test` and `make lint` green; no change under `lifetime/` unless
  the sentinel finding needs one, and then with a benchmark run.

## Test cases

1. 100 consecutive `luajit tests/run.lua unit`: 100 green.
2. 20 consecutive eager-collector runs of the unit suite under `luajit`
   and 20 under `lua5.1` with a runner that sets the two collector
   parameters before loading `tests/run.lua` and keeps `arg`: all green.
3. The sentinel test with a forced `collectgarbage("collect")` inserted
   between `destroy(x3)` and the first `attach` of `y1`: the expected log
   is unchanged, and the test says why.

The sentence most likely to be misread: "newest first by creation"
names the sentinel proxy's creation, not the owner's, once proxies are
pooled; the test's comment must say which one it relies on.

## Performance

No hot path. If `jit.off()` is used in a test, the compiled cost of the
measured loop stays covered by `bench/bench-scopes.lua`.

## Out of scope

- Any change to what the tests assert about order or size.
- The task 012 flakiness already fixed on its branch (`side` counts).

## Spec issues found

1. Clarification, not blocking; no change of semantics. Proxy reuse
   does **not** break "newest first by creation": in every failing
   round of the proxy-reuse test the proxies' creation order was
   x1 < y1 (x3's proxy) < y2 (x4's proxy), and each collection
   finalized its share newest first. What the test met is a case
   docs/02-semantics.md, "Reachability is the collector's", leaves
   implicit: objects dropped at one moment can die in **two**
   collections. If an incremental cycle is under way at the drop and
   a collector step runs between the drop and `collectgarbage
   ("collect")`, the cycle finishes and finalizes the dropped objects
   it had not yet marked; the call finalizes the rest. Program (the
   test before task 015, under `collectgarbage("setpause", 10)` and
   `collectgarbage("setstepmul", 1000)`, LuaJIT; Lua 5.1 can do the same
   but was not seen to):

   ```lua
   run_dropped(make)  -- x1, y1, y2 referenced only by make's frame until here
   test.assert_deep_eq(log, {...})  -- allocates: the running cycle may finish here
   collectgarbage("collect")
   -- seen: y1, x1 | y2 and x1 | y2, y1 (two cycles, each newest first)
   ```

   The existing sentence "The call is a statement of its own, in the
   frame that dropped the reference" comes close. A sentence after it
   would say it outright, for example: "Objects dropped together die in
   the same collection only when no collector step runs between the drop
   and the call. A test that checks their order releases them by
   assignments that allocate nothing and calls `collectgarbage
   ("collect")` next." The test now does exactly this; the doc text is
   for a `/spec-change` if the human wants it.

## Review log

### Round 1: APPROVE

Head `83f22a1`. `make test` 333/333 under `lua5.1` and `luajit`,
conformance 75/75, trial matches; `make lint` clean. `luajit
tests/run.lua unit` 100/100; eager runner 20/20 under each interpreter;
the same runners on master reproduce all three flakes (eager LuaJIT
28/30, plain LuaJIT 59/60). Benchmarks not applicable (tests only).
The reviewer traced the proxy-reuse case through the runtime's slot
arithmetic and the two-collection split under the fix, and checked by
instrumentation that the retake decision reads only the compiler's
"trace" events, never the value read; every assertion stays an exact
equality; the expected logs are unchanged and unsorted.

- F1 (non-blocking): the rewritten comment in `tests/test-sentinel.lua`
  said the kept proxies move down over the hole, which this program
  does not do (both disarms take the last-slot path). Applied by the
  orchestrator in the approval commit.
- Orchestrator rulings: the priming call is acceptable; the retake
  limit of 10 is acceptable.
- Spec issue (non-blocking, for the human): 02 "Reachability is the
  collector's" does not say that objects dropped together may die in
  two collections when a collector step runs between the drop and
  `collectgarbage("collect")`; the task file proposes a sentence.
