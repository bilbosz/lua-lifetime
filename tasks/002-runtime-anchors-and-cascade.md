---
id: 002
title: Runtime: anchors, dependents inside the anchor, `destroy`, cascade order, tombstones, `destroyerror`
status: todo
depends: [001, 010]
branch:
pr:
commits:
review:
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

## Review log
