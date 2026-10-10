---
id: 009
title: Treflove trial: transpile the sessions-and-listeners slice described in `xd/docs/notes/xd-in-treflove.md` and run it under LuaJIT
status: in-progress
depends: [008]
branch: task/009-treflove-trial
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
- `docs/05-decisions.md`, "Registration is `x @ lifetime.reachable`" and
  "The state record's key is a private table": the trial is where both
  are measured; the handoff
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
  registration "Registration is `x @ lifetime.reachable`" needs; the
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
per-frame cost of the event dispatch, which must equal the hand-written
version wherever no block anchors to `lifetime.scope`. Report both; they are the
first numbers from a real program.

## Out of scope

- Modifying the Treflove repository or pushing to it.
- Porting more of Treflove than the slice.
- LÖVE itself: the trial runs under plain `luajit` with Treflove's mocks.

## Spec issues found

1. **Registering in the constructor turns a collected tree's order upside
   down.** `docs/05-decisions.md`, "Registration is `x @
   lifetime.reachable`", says a class library registers its instances in
   its constructor. Doing that in Treflove's `class()` arms every
   instance's sentinel before its `init`, parents before children, so when
   the collector finds a whole subtree it finalizes the children first
   (newest first, `02-semantics.md`, "Reachability is the collector's")
   and each parent's destructor runs among tombstones: `Login:release`'s
   nested `release()` raises `attempt to index a dead table` into
   `destroyerror` (test case 3, `trial/treflove/README.md`, "A collected
   session"). Without the registration line the same collection runs in
   ownership order, because a bottom-up tree arms each anchor at its first
   link, after its dependents, and the root last. The slice needs no
   registration at all (every instance with a `release()` is anchored or
   is an anchor). "What a destructor may assume" (02, "Cascading death":
   "my dependents are still here and die right after me") is qualified
   only elsewhere ("Ownership order holds for every death the program
   causes; the collector's deaths follow its order"), and the decision does
   not mention the cost. Not changed here; for the human: whether the
   decision should recommend registering, registering after `init`, or
   leaving arming lazy, and whether "What a destructor may assume" should
   name the exception. The trial asserts both runs.
2. **A hook on `(a, b)` cannot tell that the other anchor is dying.**
   Idiom B's hook learns that the form went first only from a flag the
   form's `release()` sets; when the cascade reaches an input before the
   form (one owner, the form attached first), the hook runs while the form
   is dying but before its body, and unlinks from it. `lifetime.alive` is
   `true` for a dying object and nothing in the `lifetime` table tells
   dying from alive. This is the case `docs/06-open-questions.md`,
   "Whether a hook or destructor learns which anchor died", would settle;
   the trial's third run uses the shape where the form's body runs first
   and records the other in the README (finding 8).
3. **An answer for `docs/06-open-questions.md`, "How an embedding host
   announces program end"**, which says task 009 settles where Treflove
   puts the call: in a `love.quit` callback registered by
   `App:register_love_callbacks` (`app/app.lua`), which LÖVE runs on every
   quit path before closing the state. Not exercised (LÖVE is out of
   scope); moving the entry to the decision log is a `/spec-change`.

## Review log
