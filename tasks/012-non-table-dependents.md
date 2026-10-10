---
id: 012
title: Runtime: functions, coroutines and userdata as dependents (the weak-keyed side table)
status: in-progress
depends: [004]
branch: task/012-non-table-dependents
pr:
commits:
review:
---

## Goal

A function, coroutine or userdata can be a dependent (`f @ a`, `co @
lifetime.pin(a)`, `destroy(f)`, `lifetime.of(f)`), with its state record
in the weak-keyed side table of `docs/03-runtime.md`, and dies by cascade,
by `destroy` and by the collector like a table, except that it cannot be
emptied: the runtime remembers the death so that `lifetime.alive` and `@`
see it. Replaces the `not implemented` stub task 002 left, which
positions its error inside the runtime (task 002, review finding F3), and
updates the comments in `lifetime/init.lua` that still quote the
superseded sentence of "Explicit destruction" (finding F2).

## Spec

- `docs/02-semantics.md`, "Vocabulary": objects are tables, functions,
  coroutines, userdata; "Only tables and tokens can be anchors".
- `docs/02-semantics.md`, "Acquiring a lifetime", step 1: "The result
  must be an object"; step 2: a function, coroutine or userdata as an
  anchor is `attempt to anchor to a function value` (and `thread`,
  `userdata`).
- `docs/03-runtime.md`, "The state of an object": "A dependent that is
  not a table … has no hidden field; its state record lives in a
  weak-keyed side table whose value refers to the dependent's anchors,
  never to the dependent itself, so no cycle passes through the weak
  key."
- `docs/06-open-questions.md`, "Non-table dependents after death": the
  runtime remembers the death in a weak-keyed set so that `lifetime.alive`
  and `@` see it; calls and other uses are not caught (leaning: accept;
  document). The task implements the leaning and records it in
  `docs/05-decisions.md` if the human has not settled it by then; say so
  in the handoff.
- `docs/02-semantics.md`, "Tombstones and `lifetime.alive`": `alive` is
  `false` after death; `destroy` on a dead object is a no-op.
- `CLAUDE.md`, rule 6: the side table is weak-keyed and its values never
  refer to the key.

- `tasks/007-cli-and-rockspec.md`, review round 2, runtime follow-ups
  carried here: the default `destroyerror` handler flushes `io.stdout`
  before writing to stderr, so a merged stream keeps the order of events;
  and an error re-raised by a `coroutine.wrap` function shows the
  runtime's wrapper frames above the main chunk in a traceback where the
  standalone interpreter shows `[C]: in function 'w'` (cosmetic; fix if
  a level argument or `error(e, 0)` placement removes the frames without
  changing what `pcall` returns, else record).

## Acceptance criteria

- `attach(f, false, a)` for a function, coroutine or userdata `f` links
  `f` into `a`'s list and records `f`'s anchors in a weak-keyed side table
  entry whose value holds the anchors and the sequence numbers only; the
  entry disappears when `f` is collected (`collectgarbage("collect")`
  twice; a weak-keyed probe confirms).
- `f` dies by cascade with reason `"anchor"` and by `destroy(f)` with
  `"destroy"`; after death `lifetime.alive(f)` is `false`, `attach(f, …)`
  raises `attempt to move a dead function` (and `thread`, `userdata`),
  `destroy(f)` is a no-op, `lifetime.of(f)` raises as for a dead object;
  calling a dead function is not caught (documented).
- `attach(x, false, f)` raises `attempt to anchor to a function value`
  positioned at the caller; `destroy(5)` and friends are unchanged.
- Every error the task adds is positioned at the caller, like `bad
  argument #1 to 'destroy'` (finding F3): no message carries a
  `lifetime/init.lua:` prefix.
- The comments at the `destroy`/`discard` no-op and the by-hand case cite
  `docs/02-semantics.md`, "Explicit destruction", in its current wording
  and `docs/05-decisions.md`, "`destroy` by hand inside a destructor"
  (finding F2).
- A sentinel for a reachable-only non-table dependent is not required
  (task 004 decides what a function with the term and a hook attached
  does at collection; say what this task does in the handoff).
- `make test` green under both interpreters; `make lint` clean; `make
  bench BASE=master` within the threshold, with `runtime/attach-first`
  and `runtime/move` unchanged (the side table is off the table path).

## Test cases

1. `local f = function() end; f @ a; destroy(a)`: the log shows `f`'s
   hook-free death (a dependent with no body) only through
   `lifetime.alive(f) == false` after the cascade, and
   `lifetime.dependents(a)` empty.
2. A coroutine anchored to `a`, destroyed with `a`; `coroutine.status`
   still works (not caught); `lifetime.alive(co) == false`.
3. A userdata (`newproxy(true)`) anchored and destroyed the same way.
4. `destroy(f)` directly: `alive` false; second `destroy(f)` no-op;
   `attach(f, false, b)` raises `attempt to move a dead function` at the
   caller's line.
5. Side-table entry collected: `f @ a; f = nil; collectgarbage("collect")`
   twice; a weak-keyed probe on the side table is empty and
   `lifetime.dependents(a)` is empty.
6. Error positions: `pcall(destroy, print)` and `pcall(lifetime.of, print)`
   messages carry no `init.lua` prefix.

## Performance

Hot paths: `attach` of a table must not slow down (the type test is the
only addition). Benchmarks: `runtime/attach-first` and `runtime/move`
unchanged against `master`; add `runtime/attach-function` (attach and
destroy a function dependent) for the record. Must stay free: a table
dependent never touches the side table.

## Out of scope

- Userdata as anchors (open question "Non-table anchors").
- Catching calls of a dead function.
- Hooks on non-table dependents beyond what task 003 already allows.

## Spec issues found

Found by the implementer, round 1; item 7 in round 2. Items 1, 2 and 3
were settled by the human after round 1 and are implemented in round 2;
the others say what the code does and why.

1. **The side table's edge to the anchors is a cycle through the weak key
   whenever the anchor holds its dependent** (touches the consequences of
   decision 3 of file 10; for the human). **Settled by the human** (`docs/05-decisions.md`, "Non-table dependents: remembered after death, weak anchors"; master `ca9db2d`): the record
   holds its anchors weakly; 02, "Reachability is the collector's", and
   03, "The state of an object", now say so. Round 2 flipped the code
   and the two tests named below (see "Round 2" in the review log). 03 says the side table's value
   "refers to the dependent's anchors, never to the dependent itself, so
   no cycle passes through the weak key", and 02, "Reachability is the
   collector's", says "a dependent's reference to its anchor is strong,
   as any field would be". Lua 5.1 and LuaJIT mark the values of a
   weak-keyed table whether or not the key is reachable (no ephemerons,
   decision 1), so the runtime holds every anchor of a live function
   strongly from a root. When the anchor refers back to the function by
   any path, the key stays reachable through the value, and neither is
   ever collected; their destructors never run, until something calls
   `destroy`. Two common shapes hit it:
   - `self.on_click = function() … end @ self` (or a listener the anchor
     keeps in an emitter it owns): `self` is immortal. With a table
     dependent this is the ordinary cycle decision 3 frees ("A hook whose
     closure mentions `self` is a cycle too, so attaching a cleanup hook
     no longer makes an object immortal").
   - `co @ lifetime.pin(a)`: the anchor's `strong` list holds `co` and
     `co`'s record holds `a`, so a pinned function, coroutine or
     userdata makes its anchor immortal once nothing else holds the
     anchor; 02's "A subtree nobody outside holds ... dies as a whole when
     the collector finds its root" does not hold for it.

   The alternative is one line: the side record holds its anchors weakly
   (`setmetatable(record, {__mode = "v"})`; the sequence numbers are
   numbers and stay). Then nothing leaks, and the observable difference
   is the 02 sentence above: an anchor referred to only through the
   formulas of its non-table dependents is collected, and its cascade
   kills them with `"anchor"` while something may still hold them. There
   is no third way on these hosts: a function has no field of its own
   (its environment is its globals), a coroutine neither, and a
   userdata's environment table belongs to its maker (Lua 5.1's own file
   handles read their `__close` from it). Implemented: the letter of 03
   and 02 (strong). Tests pin both halves: "a dependent's reference to
   its anchor is strong: the anchor lives while the function does" and
   "known limitation: a pinned function and an anchor that nothing else
   holds are not collected", which flips if the human chooses the weak
   record.
2. **A `__destroy` of a function, coroutine or userdata the collector
   finds does not run.** **Settled by the human** (`docs/05-decisions.md`, "Non-table dependents: remembered after death, weak anchors"; master `ca9db2d`): such a dependent carries no
   sentinel and one the collector finds dies silently (02,
   "Reachability is the collector's"); tested in round 2 ("a function,
   coroutine or userdata the collector finds dies silently"). 02, "`__destroy` and reasons", rule 1 reads
   `__destroy` for these from their type's metatable, and rule 7 says the
   runtime notifies the objects it has seen; "Reachability is the
   collector's" says every unreachable object "has had its cascade run,
   with reason `"unreachable"`" after `collectgarbage("collect")`. For
   these objects nothing runs at collection: no sentinel can be made
   (the proxy's metatable would hold the object: a cycle through the weak
   key), and an unreachable object cannot be handed to its `__destroy`
   unless the runtime kept it alive. The acceptance criteria allow it ("A
   sentinel for a reachable-only non-table dependent is not required");
   recorded in the decision entry (`docs/05-decisions.md`, "A dead
   function, coroutine or userdata is remembered, not caught"); 02 does
   not say it yet. The case that matters is a `newproxy(true)` userdata
   with a `__destroy` registered with `@ lifetime.reachable`.
3. **Error texts for a function, coroutine or userdata.** 02 names the
   table forms only. By analogy, with Lua's type name: `attempt to move a
   dying function`; `attempt to move an anchored function during
   destruction`; `attempt to move a dead function (<name>, died at
   <where>, <reason>)` from `@` (the criterion's text, with the
   parenthesis a tombstone's message has); `attempt to index a dead
   function (…)` from `lifetime.of` and `lifetime.format` ("raises as for
   a dead object": for a table that is the tombstone's `index` message).
   A sentence in 02 would fix them. **Settled by the human** (`docs/05-decisions.md`, "Non-table dependents: remembered after death, weak anchors"; master `ca9db2d`): the texts above
   are now in 02, "Tombstones and `lifetime.alive`"; round 2 compares
   each whole for all three types ("the error texts for a function, a
   coroutine and a userdata, exactly").
4. **Test case 6 as written no longer raises.** `pcall(destroy, print)`
   and `pcall(lifetime.of, print)` were the stub's errors; with the task
   done they succeed (and the first kills `print` for the rest of the
   process: `lifetime.alive(print)` becomes `false`, the call still
   works). The test checks every error the task adds instead (anchoring
   to a function, coroutine or userdata, `@`, `of` and `format` on a dead
   function, the argument errors) for the caller's position and no
   `init.lua`, and that `pcall(destroy, f)` of a fresh function returns
   `true`.
5. **`lifetime.format` of a function.** Not in the task's list, but 02
   says `format` renders "an object's formula", and a function anchored
   with `@` has one; before, it raised `lifetime expected, got function`.
   Implemented as for a table: `(a, reachable)`, `a` when pinned,
   `reachable` on the default lifetime, the dead message after death.
6. **A finalized userdata and its anchor's list** (found while tracing,
   fixed; no semantic change). A userdata with a `__gc` of its own is
   cleared from its anchor's weak `deps` in the collection that finalizes
   it, while its key in the side table stays for that collection (02,
   "Host"). If another finalizer of the same collection links to the
   anchor and a compaction renumbers the list, the userdata's old slot
   goes to another dependent, and a `destroy` of the userdata from its own
   `__gc` unlinked that other dependent. The side path now unlinks only a
   slot that still holds the object (`unlink_side`); test "a userdata
   finalized by its own __gc never unlinks a slot compaction gave to
   another" reproduced it on both interpreters before the fix. Such a
   userdata is not walked by its anchor's cascade after that collection
   (it is no longer in the list); if its `__gc` resurrects it, `alive`
   reads `true` until it is destroyed or collected, and since round 2 its
   record's slot for an anchor reads `nil` once the collector has taken
   that anchor (every read of a record's anchors skips it; test "a record
   whose anchor the collector took: of, format, @ and destroy skip the
   cleared slot").
7. **A userdata resurrected by its own `__gc` drops out of its anchors'
   lists at every later collection** (round 2; for the human, no code
   change). Both hosts keep a finalized userdata's "finalized" mark for
   good and clear it from weak values in every collection, not only in
   the one that ran its `__gc` (a probe: resurrect a `newproxy(true)`,
   hold it strongly, store it in a `__mode = "v"` table, collect: the
   entry is gone on Lua 5.1 and on LuaJIT). So once a userdata dependent
   has been resurrected, `@` links it into its anchors' weak `deps` and
   the next collection unlinks it again: an anchor's cascade, a scope
   exit and `lifetime.dependents` miss it, and it dies only by its own
   `destroy` (or not at all). The record still names the anchors, so
   `lifetime.of` and `lifetime.format` report a formula the runtime no
   longer enforces. Neither 02 nor 03 says this; the cases are a
   userdata with both a `__gc` and a resurrecting finalizer, which LÖVE
   objects are not. A sentence in 02, "Host" or "Reachability is the
   collector's", would record it; a pinned link (`strong`) would keep
   such a userdata in the list, at the price of keeping it alive. The
   round 2 test pins the cascade with `collectgarbage("stop")` around
   the move for this reason.

## Review log

- Implementer, round 1: the runtime side in `lifetime/init.lua`
  (`side`, `new_side_state`, `attach_side`, `destroy_side`,
  `unlink_side`, `dead_side_message`, `deps.other`), tests in
  `tests/test-functions.lua` (26 cases), `runtime/attach-function` in
  `bench/bench-runtime.lua` and its row in `bench/README.md`, the
  decision entry in `docs/05-decisions.md`. `docs/06-open-questions.md`,
  "Non-table dependents after death", is left for the done chore to move
  or mark settled (not among this task's files).
- Implementer, round 1, task 007's notes: the default `destroyerror` and
  the fallback report of a failing handler call `io.stdout:flush()`
  before writing to stderr (tested in a child process with both streams
  in one file). The `coroutine.wrap` frames: on LuaJIT `wrapped` raises
  with `return error(err, 1)`, a tail call that replaces the runtime's
  frame, so the traceback reads `[C]: in function 'w'` as the
  standalone interpreter's does and the message is unchanged; on Lua 5.1
  a tail-called C function keeps the caller's frame, so no level or
  `error(e, 0)` placement removes the frames there, and the plain call
  stays (same message). Chosen at load time by a probe (`TAIL_RAISE`).
- Implementer, round 1, performance: `runtime/attach-function` costs
  about 4.2 us on Lua 5.1 and 1.5 us on LuaJIT per attach-and-destroy
  (ratios 11.7 and 6.9 to the baseline). Most of it is the host's
  weak-keyed table: a plain-Lua loop that stores a fresh closure with an
  11-field record in a weak-keyed table costs 1.0 us (LuaJIT) and 2.1 us
  (Lua 5.1) per entry against 0.16 and 0.39 us without the table (a
  value outlives its key by one collection, and weak tables are walked
  again in the atomic step); a 7-field record did not reliably help, and
  `destroy`'s `debug.getinfo` is the rest. It is the cost of the design
  of 03, paid only by non-table dependents.
- Implementer, round 1, `make bench BASE=master`, two invocations (the
  second on the final runtime, `610c3c5`): nothing marked in either.
  `runtime/attach-first` branch/base 1.037 and 1.038 (Lua 5.1), 0.970
  and 1.110 (LuaJIT; pairings 0.993 and 1.227 in the second, noise by
  the two-run rule); `runtime/move` 1.001 and 1.003 (Lua 5.1), 0.992 and
  1.012 (LuaJIT); the plain-Lua `plain/transpiled` ratio within 1.6% of
  1.0. `run/plain.lt` reads 1.044 and 1.079 (Lua 5.1), 1.054 and 1.056
  (LuaJIT), under the threshold: the startup of `lifetime run` parses the
  runtime file, which grew by 15 KB (166 comment lines, 227 lines of
  code and blank lines); `loadfile` of it costs 157 us more on Lua 5.1
  and 175 us more on LuaJIT, running it 4 to 9 us more.
- Implementer, round 2 (after the human's ruling, `docs/05-decisions.md`,
  "Non-table dependents: remembered after death, weak anchors", merged on
  master in `ca9db2d`). Merged master twice (`ca9db2d`, resolving
  `docs/05-decisions.md` with master's entry, which replaces round 1's
  "A dead function, coroutine or userdata is remembered, not caught";
  then `a17ac03`, task 014's spec, docs and examples only). Code:
  `new_side_state` gives the record `__mode = "v"` (the shared
  `WEAK_VALUES`), so a function, coroutine or userdata dependent no
  longer keeps its anchor alive; every read of a record's anchors
  (`destroy_side`, the move in `attach_side`, `lifetime.of` through the
  new `side_value_of`, `lifetime.format`) skips a slot the collector has
  cleared; comments cite the new 02 and 03 sentences and the new
  decision. Tests (`tests/test-functions.lua`, 31 cases): the two that
  pinned the strong edge are flipped ("a function dependent does not
  keep its anchor alive; a table dependent does"; "co @
  lifetime.pin(a) with a dropped: both die in cascade order and are
  collected"); new: the asymmetry as transpiled code, with the deaths
  between the program's own lines at the `collectgarbage` statement;
  `self.cb = function() ... end @ self` dropped; a record whose anchor
  the collector took (of, format, `@`, `destroy`; it fails without the
  guards); the silent death of a collector-found non-table dependent;
  the error texts compared whole for all three types. The compaction
  test now holds `u4`'s new anchor, which the weak record no longer
  keeps (it failed under an eager collector otherwise). Kept as round 1
  chose (human's answer): the tombstone parenthesis and the `index` verb
  in the dead messages, the stdout flush in both reports. Spec issue 7
  is new.
- Implementer, round 2, eager collector (`collectgarbage("setpause", 10)`
  and `collectgarbage("setstepmul", 1000)` before the suite, the effect
  of the `LUA_INIT` the orchestrator named): `tests/test-functions.lua`
  31 passed under both interpreters, five runs each; the runtime suites
  (`test-harness`, `test-runtime`, `test-scopes`, `test-sentinel`) 161
  passed under both.
- Implementer, round 2, `make bench BASE=master` (`a17ac03`, whose
  `lifetime/` is `ca9db2d`'s), two invocations: the first marked
  `run/plain.lt` on Lua 5.1 (pairings 1.131 and 1.129), the second did
  not (1.014 and 1.034) and marked nothing; noise by the
  two-invocation rule. `runtime/attach-first` 0.853/1.109 then
  0.986/0.816 (Lua 5.1), 0.901/1.123 then 0.957/0.907 (LuaJIT);
  `runtime/move` 1.080/1.022 then 1.018/1.027 (Lua 5.1), 1.236/0.799
  then 0.991/0.824 (LuaJIT). `plain/transpiled` in-process ratio 1.058,
  1.035, 1.021, 1.189 (Lua 5.1) and 0.959, 1.062, 1.012, 0.974 (LuaJIT);
  the chunk never loads the runtime, so this is the machine (load
  average about 1 from other sessions). `runtime/attach-function`,
  absolute: 4148 and 4227 ns, then 3983 and 4022 ns (Lua 5.1); 1617 and
  1810 ns, then 1961 and 1971 ns (LuaJIT). An A/B against round 1's
  runtime (three alternating processes each) reads 3.5 to 4.0 us for
  round 1 and 4.1 to 5.1 us for round 2 on Lua 5.1, 1.43 to 1.76 us
  against 1.66 to 1.77 us on LuaJIT: the `setmetatable` per record and
  the record's place in the collector's weak list, a few percent, forced
  by the weak record of 03.
