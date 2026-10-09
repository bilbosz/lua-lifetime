---
id: 003
title: Runtime: scope records, hooks
status: done
depends: [002]
branch: task/003-runtime-scopes-hooks
pr: https://github.com/bilbosz/lua-lifetime/pull/22
commits: a9bc8ce4751b07b2033f54040d8ff986b2f1da29
review: APPROVE (round 1)
---

## Goal

The runtime provides what the emitter's block code will call:
`lifetime.enter(line)` / `lifetime.exit(record, line)` for scope records,
the per-coroutine scope stack and the replacements for `pcall`, `xpcall`,
`coroutine.resume` and `coroutine.wrap` that unwind it on the error path,
and `lifetime.hook(f, name, a1, …)` for hooks. Tests drive them by
hand, writing the block prologue and epilogue of `docs/04-transpiler.md`
as generated code would. Nothing in this task runs per function call:
there is no `caller` anchor and no depth counter (`docs/05-decisions.md`,
"`caller` is removed").

## Spec

- `docs/02-semantics.md`, "Scopes: `lifetime.scope`": a scope's dependents die at
  block exit "by any route"; each entry is a new scope; "no bookkeeping
  runs per call".
- `docs/02-semantics.md`, "Hooks: the `!@` operator": default lifetime is the
  block's scope; a hook is pinned; "A hook on an object runs **after**
  that object's `__destroy`, interleaved with the object's other
  dependents by attachment order, most recently attached first"; called
  as `fn(reason)`; metatable `"hook"`; `discard` cancels, `destroy` runs,
  `@` re-targets; errors follow the destructor rule. "Named hooks": a
  named hook's `tostring` is `hook NAME`; after it runs it is dead,
  `lifetime.alive` is `false`, `destroy` and `discard` are no-ops.
- `docs/02-semantics.md`, "Cascading death": "A scope has no body: scope
  exit destroys the objects anchored to it in reverse attachment order".
- `docs/02-semantics.md`, "Scopes: `lifetime.scope`": the error path
  unwinds at the catch site, innermost first, before the catching call
  returns; a record a hidden catch left behind dies at the next `exit`
  that finds it above itself.
- `docs/02-semantics.md`, "Errors in destructors": while the runtime
  unwinds on an error, later destructor errors go to `destroyerror` and
  the original continues.
- `docs/02-semantics.md`, "Coroutines": a scoped block may yield; an
  error that ends a coroutine unwinds its scopes inside `resume`/`wrap`.
- `docs/03-runtime.md`, "Scope records" and "The scope stack and the
  error path": a record exists only for a block that anchors to it; the
  stack per coroutine; the four wrappers, allocation-free; `resume` swaps
  `S.stack`, `yield` is untouched.
- `docs/03-runtime.md`, "Performance": `enter`/`exit` is "one record (a
  small table) per entry"; a function call costs what it costs in Lua.

## Acceptance criteria

- `lifetime.enter(line)` returns a scope record with metatable `"scope"`
  and pushes it on the running coroutine's stack; `lifetime.exit(record,
  line)` pops it and runs the cascade with the record as root and no
  body, dependents in reverse attachment order with reason `"anchor"`,
  and `<where>` for their tombstones is `chunk:line` of the exit.
- After `require("lifetime")`, `pcall`, `xpcall`, `coroutine.resume` and
  `coroutine.wrap` are the runtime's: on an error they unwind every record
  pushed since the call began, innermost first, with destructor errors
  routed to `destroyerror`, and return or re-raise exactly what the
  originals would; `<where>` for an unwound record's dependents is
  `chunk:line` of the block's `end` passed to `enter`. The wrappers
  allocate nothing (`collectgarbage("count")` around a loop of `pcall`s
  that raise through no scoped block).
- `exit(record, line)` with records above `record` on the stack unwinds
  them first, innermost first, then pops and runs `record`'s cascade.
- `lifetime.scope` is the marker of `docs/03-runtime.md`, "Scope
  records": `tostring` gives `lifetime.scope`, indexing it raises
  `attempt to index lifetime.scope`, and `attach(x, false, lifetime.scope)`
  raises `attempt to anchor to lifetime.scope through a variable`.
- The runtime exports no `drop`, `caller` or `exit_main`; requiring it
  leaves `coroutine.create`, `coroutine.yield`, `coroutine.status`,
  `coroutine.running` and `error` untouched (`rawequal` before and after
  `require`).
- A scope record is a plain small table: `enter()` in a loop of `n`
  iterations allocates `n` records and nothing else when nothing is
  attached (assert with `collectgarbage("count")`).
- `lifetime.hook(f, name, a1, …, an)` creates a hook: a table with
  metatable `"hook"`, attached pinned to the anchors (a scope record
  included) through their `hooks` lists, whose body calls `f(reason)`;
  `lifetime.hook(5)` raises `attempt to defer a number value`; calling or
  indexing a hook raises the hook errors.
- With a name, `tostring(h)` is `hook NAME` and `lifetime.format(h)` is
  `hook NAME`; with `nil`, `tostring(h)` is `hook: 0x…`.
- `destroy(h)` on a live hook runs `f("destroy")` once; afterwards
  `lifetime.alive(h)` is `false` and a second `destroy(h)` or `discard(h)`
  does nothing.
- A hook attached to an object runs after the object's `__destroy` and in
  its position among the dependents by attachment sequence.
- `discard(h)` never runs `f`; `destroy(h)` runs it now with `"destroy"`;
  `attach(h, false, other)` moves it.
- `make test` green under both interpreters; `make lint` clean.

## Test cases

1. Scope order: `enter`; `f @ s`; hook "after f"; `g @ s`; hook "runs
   first"; `exit`: log `runs first, g, after f, f` (the example in the spec).
2. Hook after body: `conn` with a logging `__destroy`; hook on `conn`
   logging "hook sees " .. conn.id; `destroy(conn)`: log `conn, hook sees
   conn` and the hook ran while `conn` was still indexable.
3. Nested records: `enter` an outer record, `enter` an inner one, attach
   `x` to the outer and `y` to the inner; `exit` the inner: only `y` dies;
   `exit` the outer: `x` dies. Records are independent tables; nothing
   links them.
4. Records in a coroutine: a coroutine body that `enter`s a record,
   attaches `x`, yields, and `exit`s after the resume; `x` dies at the
   `exit`, after the resume, and the main thread's records are untouched.
5. Error path: `enter` two nested records with logging dependents `x`
   (outer) and `y` (inner), then `error("boom")` inside `pcall`; the log
   reads `y, x` before `pcall` returns `false, "…: boom"`, and the stack is
   back at its depth before the call. The same with `xpcall` and a
   handler that logs first: `handler, y, x`. A dependent whose body raises
   `"d"` during that unwind sends `"d"` to `destroyerror` and `"boom"`
   still comes out of `pcall`.
5a. Hidden catch: a `pcall` captured before `require` catches an error
   that left record `r` behind; the next `exit` of an outer record logs
   `r`'s dependents first, then its own.
5b. Coroutine error: a coroutine that `enter`s a record, attaches `z`,
   and raises; `coroutine.resume` returns `false` after `z` died; the
   main stack is untouched. The same through a `coroutine.wrap` function,
   which re-raises after `z` died.
6. Cancel and re-target: `discard` then `exit` logs nothing for the hook;
   a hook moved to `registry` runs at `destroy(registry)` with `"anchor"`.
7. Suspended coroutine collected: a coroutine that `enter`s a record,
   attaches `x` (with a logging `__destroy`) and yields, then is dropped;
   after `collectgarbage("collect")` twice the log shows `x` dying with
   reason `"unreachable"` (the record's sentinel, task 004 provides it;
   until then this case is skipped and named in the review log).

The sentence most likely to be misread: "A hook on an object runs after
that object's `__destroy`", given that for a *scope* hooks are still
last-deferred-first-run. Cases 1 and 2 together pin both readings.

## Performance

Hot paths: `enter`/`exit` of a scope record (per block entry), the four
wrappers (per `pcall` or resume), hook creation. Benchmarks: a loop body
with one scoped object against hand-written cleanup; `enter`/`exit` of
an empty record in a loop; `pcall` of an empty function through the
wrapper against the original, both under `luajit -jv` to show the loop
still compiles. Must stay free: a function call, which the runtime never
sees; a block with no record, which never calls the runtime.

## Out of scope

- Generated code: task 006. Tokens, `pin`, sentinels: task 004.

## Spec issues found

Found by the implementer, round 1. None changes the semantics; each says
what the code does and why, for the reviewer and the human to decide.

1. **`chunk:line` from `enter(line)` and `exit(record, line)`.** The
   acceptance criteria want `<where>` to be `chunk:line` of the exit (or of
   the block's `end` for an unwound record), while `docs/04-transpiler.md`,
   "Blocks", writes `lifetime.enter(<line of end>)` and `lifetime.exit(__s1,
   <line>)`. The runtime cannot learn the chunk name without `debug.*`,
   which CLAUDE.md forbids on a per-block path. Implemented: the argument
   is the position the tombstone reports, stored as given and rendered
   with `tostring`; the tests pass `"chunk:line"` strings. Task 006 should
   emit the position as one constant string (`lifetime.enter("f.lt:12")`),
   which costs nothing per entry. 04 could say "the position of the
   block's `end`, as the constant `"chunk:line"`".
2. **The coroutine-stack table would keep coroutines alive.**
   `docs/03-runtime.md`, "The scope stack and the error path", keeps a
   coroutine's stack "in a weak-keyed table by coroutine whose values never
   refer to the key". They can: a stack holds its records, a record holds
   its hooks strongly (`strong`), and a hook that closes over its own
   coroutine refers back to the key. Lua 5.1 has no ephemerons, so such a
   coroutine, suspended and dropped, would never be collected and its
   hooks never run (CLAUDE.md, rule 6). Implemented: the table is weak in
   keys and values, and every record holds its stack (`stack` field), so a
   stack lives exactly while its coroutine is running or has an active
   record; test "a suspended coroutine whose hook refers to it can still
   be collected". Consequences: a coroutine's stack table is re-created on
   the next resume after a collection found it empty (one small table, not
   per resume); and records a hidden catch left in a suspended coroutine
   with no active record are then reached only through their sentinels
   (task 004), not at a later exit. 03's sentence could read "weak in keys
   and values; each record refers to its stack".
3. **The marker outside the anchor position.** 02 and 03 say `@` refuses
   `lifetime.scope` with `attempt to anchor to lifetime.scope through a
   variable`, and say nothing about the marker as the *left* operand, or
   passed to `destroy`, `discard`, `lifetime.of` or `lifetime.format`.
   Implemented: the same message for both operands of `@` and `!@`;
   `destroy`, `discard` and `lifetime.of` raise `bad argument #1 to 'NAME'
   (object expected, got lifetime.scope)` and `lifetime.format` `(lifetime
   expected, got lifetime.scope)`, after task 002's `got lifetime` for a
   lifetime value; `lifetime.dependents` returns `{}` as for a value.
   `getmetatable(lifetime.scope)` is `"lifetime.scope"` (03 says only "a
   private metatable"). A scope record reached through a lifetime value
   (`lifetime.of(x)[1]`, the only way to name one) is refused by `destroy`
   (`object expected, got scope`, from "`destroy` of a scope is
   impossible") and by `@` as the moved object (`attempt to anchor a scope
   value`); anchoring *to* it through the value works while the block is
   active. None of these texts is in the spec.
4. **Where Lua 5.1 makes the replacements differ from the originals.**
   "Re-raise exactly what the originals would" holds for every value and
   error the comparison test checks, on both hosts, with two exceptions on
   Lua 5.1 only, both host limits of a Lua function standing in for a C
   function: (a) an argument error the original raises inside the
   replacement (`pcall()`, `xpcall(f)`, `coroutine.resume(5)`,
   `coroutine.wrap(5)`) carries the runtime's position instead of the
   caller's, and `wrap`'s names `create`; LuaJIT's messages carry no
   position, so they match there. (b) A string error re-raised by a wrap
   function that its caller *tail-called* (`return w()`): the original,
   a C function, keeps the caller's frame and prefixes its position; the
   replacement's caller frame is gone and no prefix is added. Called
   without a tail call, both hosts match. `wrap` finds once, at load, how
   the host re-raises (whether a number gets the prefix, and the error
   level across a tail call), so the runtime does not read `jit`.
5. **Hooks are in `strong`, not `hooks`.** The acceptance criteria say
   hooks are attached "through their `hooks` lists"; `docs/05-decisions.md`,
   "Pinned dependents are held by their anchors", names that table
   `strong`, which is what is implemented. Pinned dependents (a formula
   without the `reachable` term, `attach(x, true, ...)` today) go there
   too, as 03 says, so task 004 has only `lifetime.pin` to add.
6. **`<where>` of records a hidden catch left behind.** 02 says they die
   "at the next scope exit ... that finds it above itself". Implemented:
   their dependents' tombstones report the record's own `line` (its
   block's `end`), as for an unwound record, not the line of the exit that
   found them; that exit is one statement for the error rule, so its first
   destructor error is raised after all of them.
7. **`lifetime.alive(h)`** is task 004's; the test of "afterwards
   `lifetime.alive(h)` is `false`" checks it when it exists and checks the
   tombstone (`getmetatable(h) == "dead"`) now.

## Review log

- Implementer, round 1: test case 7 (a suspended coroutine dropped with a
  record whose dependent dies `"unreachable"`) is not tested: it needs the
  record's sentinel, which task 004 provides. A comment in
  `tests/test-scopes.lua` marks the place.
- Implementer, round 1, performance: with `luajit -jv`, the loops of
  `scope/enter-exit-empty` and `scope/pcall-empty` compile with no trace
  abort; those of `scope/loop-one-object` and `scope/hook-on-scope` abort
  about 31 times during warm-up with "inner loop in root trace" at the
  tombstone's `for k in next, obj` loop (task 002's), then run compiled
  (`-jp=v`: no interpreted time for the hook loop, 4% for the one-object
  loop). A loop-free tombstone (a tail-recursive clear) removed those
  aborts but made `runtime/move` about 1.8 times as slow on LuaJIT after
  `runtime/attach-destroy-100` in the same process, reproducibly, from
  every load path tried (45 to 73 ns against master's 25), and was
  reverted: task 002's benchmarks must stay within the threshold. The
  scope loop's single entry and the single-anchor unlink stay loop-free.

### Round 1: APPROVE

Suite on `58c3447`: unit 202/202 under lua5.1 and luajit (five runs, no flakiness in the eleven latent cases), conformance 5/5 under both, lint clean (27 files). `make bench BASE=master` twice: nothing marked among task 002's, the transpiler's and the plain benchmarks; in-process `plain/transpiled` 0.978 to 1.026. Replacements against master's C originals, ns per 10 operations, Lua 5.1 / LuaJIT: `scope/pcall-empty` 1204 and 1230 vs 534 / 25.5 and 27.0 vs 21 (marked once); `scope/pcall-error` 2162 and 2139 vs 1227 / parity; `scope/resume-yield` 1760 and 1766 vs 752 / 641 vs 477 and 484 (marked both runs, both hosts). The orchestrator's decision: the forced cost of the catch-site design, recorded in `docs/03`, "Forced, and measured". Wrapper shape judged minimal: a wrapper and its continuation, two Lua vararg frames (a single frame cannot inspect `ok` without packing), +72 ns per `pcall` and +101 ns per `resume` on 5.1, +0.5 and +1.6 ns on LuaJIT. Trace aborts and the bisection confirmed: 37 warm-up aborts at the tombstone loop then compiled; the abort-free variant makes `runtime/move` 46 vs 25 ns; the loop is the right trade. Traced by hand: a scoped block with hooks and dependents unwound by `pcall` (`h2, a, b, h1`, tombstone at the `enter` line); nested coroutines main, A, B with records and yields at every level and B raising; a `__destroy` resuming a raising coroutine during a scope exit; yield across `pcall` under both hosts.

- F1 (non-blocking): `lifetime.exit(nil, …)` on an empty stack pops before `rec.deps` raises, leaving `stack.n` at -1. Fix in task 004: move the pop after the `rec.deps` read (free). `exit` is emitter-facing.
- F2 (non-blocking): nested-coroutine stack swapping is covered only by the reviewer's trace. Task 004 adds the main, A, B case.
- Question for the spec: `f !@ lifetime.reachable` makes a hook with no anchor and no term that renders `()` and never runs; `docs/02`, "Hooks", says the collector may run it, `docs/03`, "The sentinel", says never a hook. Settled by the orchestrator in the done chore: a hook whose formula is `lifetime.reachable` alone carries a sentinel and runs with `"unreachable"` when collected; `format` renders `reachable`; task 004 implements it with the sentinel.
- Docs brought in line in the done chore: 03 "weak-keyed" (weak in keys and values, each record holds its stack; hidden-catch records in a suspended coroutine die through their sentinels), "one wrapper frame", the marker's texts; 04 `enter` takes the position as a constant `"chunk:line"` string.
- Follow-ups for task 004 besides F1 and F2: the eleven `tests/test-runtime.lua` cases that hold no reference to dependents with the term (lines 359 to 710); the LuaJIT-only gain of a plain `setmetatable` for an unprotected tombstone (470 to 355 ns on the one-object loop, 3 to 7% cost on 5.1's destroy-heavy benchmarks) left for a decision.
