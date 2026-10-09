---
id: 012
title: Runtime: functions, coroutines and userdata as dependents (the weak-keyed side table)
status: todo
depends: [004]
branch:
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

## Review log
