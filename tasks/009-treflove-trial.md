---
id: 009
title: Treflove trial: transpile the sessions-and-listeners slice described in `xd/docs/notes/xd-in-treflove.md` and run it under LuaJIT
status: todo
depends: [008]
branch:
pr:
commits:
review:
---

## Goal

A copy of the Treflove slice that idioms A and B of
`xd/docs/notes/xd-in-treflove.md` describe (`ConnectionManager:remove`,
`Connection`, `Session`, `Login`, `RemoteProcedure`, `AssetManager`'s
per-session RPs, and the `FormScreen`/`Input` listener hook) lives under
`trial/treflove/` as `.lt` files, transpiles, and runs under LuaJIT with
the test doubles Treflove's `tests/lib/mocks.lua` provides, showing one
`destroy(connection)` tearing down the five-level tree in the order of
decision 10 and an input unlinking itself from its form. The Treflove
repository itself is not modified.

## Spec

- `docs/02-semantics.md`, "Cascading death" (the order the trial must
  show), "Hooks: the `!@` operator" (the input hook), "Tombstones" (what the
  nested `release()` calls see), "Tokens: `lifetime.token`" (the "logged in" period,
  idiom C, if the slice reaches `Session:login`).
- `xd/docs/notes/xd-in-treflove.md`, sections 1 and 2, idioms A and B: the
  code shape to reproduce, with `lifetime.all(x, lifetime.reachable)`
  spelled `@ x` and `lifetime.all(form_screen, self)` spelled `@
  (form_screen, self)`.
- `xd/docs/09-lessons-from-treflove.md`, lessons 1 to 5 and 8: what to
  look for; under file 10 lessons 1 and 4 are expected to reverse.
- `docs/06-open-questions.md`, "Registering plain objects" and "The hidden
  field is visible": the trial is where both are measured; the handoff
  reports what Treflove's `class()` and `table.to_string` needed.
- `CLAUDE.md`, rule 3: the trial asserts order.

## Acceptance criteria

- `trial/treflove/` holds the `.lt` sources, a `README.md` naming the
  Treflove commit they were copied from and every edit made, and a
  `run.lua` that transpiles them and runs the scenario under `luajit`.
- The scenario logs `destroy(connection)`: `Connection`'s body first,
  then its dependents most recently attached first, recursively, and the
  log is asserted as one sequence.
- The `Input` hook unlinks the input from the form when the input dies
  first, and does nothing when the form dies first or both die in one
  cascade; both are asserted.
- A `release()` that calls a nested `release()` works (lesson 4 reversed)
  and is kept, to show it is redundant, not wrong.
- The trial runs with Treflove's `utils/class.lua` changed by the one line
  the note describes (`__destroy` forwarding to `release`) plus whatever
  registration the open question "Registering plain objects" needs; the
  handoff reports exactly what was needed.
- `make test` includes `trial/treflove/run.lua` when `luajit` is present
  and skips it with a message otherwise; green; `make lint` clean.

## Test cases

1. The connection teardown: the exact log sequence, written in the task
   branch's `trial/treflove/README.md` before running, then compared.
2. Input before form, form before input, both in one cascade: three
   runs, three asserted logs.
3. A collected session (dropped from the server's table, `collectgarbage
   ("collect")` twice): its RPs' `stop()` ran, the weak-key `sessions`
   entry is gone.

The sentence most likely to be misread: lesson 1 of
`xd/docs/09-lessons-from-treflove.md` ("held objects pin what they
reference"), which under decisions 3 and 4 no longer holds: a `child @
parent` with a back-reference is collectable as a cycle. Case 3 pins it.

## Performance

Measure the Treflove slice: time for one connect-login-disconnect cycle
transpiled against Treflove's hand-written version under LuaJIT, and the
per-frame cost of the event dispatch with the `caller` prologue in place.
Report both; they are the first numbers from a real program.

## Out of scope

- Modifying the Treflove repository or pushing to it.
- Porting more of Treflove than the slice.
- LÖVE itself: the trial runs under plain `luajit` with Treflove's mocks.

## Spec issues found

## Review log
