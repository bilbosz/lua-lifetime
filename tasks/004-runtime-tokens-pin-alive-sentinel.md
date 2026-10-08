---
id: 004
title: Runtime: `lifetime.token`, `lifetime.pin`, `lifetime.alive`, reachable-only destructors via `newproxy`, `collectgarbage`
status: todo
depends: [002]
branch:
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
  has had its cascade run; the order among objects one collection finds
  is undefined; a destructor run by the collector can rely only on itself
  and its fields; weak entries clear one collection later.
- `docs/03-runtime.md`, "The sentinel": the proxy's own metatable holds
  the owner; which objects carry a sentinel; the finalizer skips an object
  already dead.
- `docs/06-open-questions.md`, "Errors in finalizer-run destructors": the
  task implements the leaning (route to `destroyerror`) **only if** the
  human has settled it by then; otherwise it lets the error propagate as
  5.1 does and records the choice under *Spec issues found*.

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
- Every object one collection finds unreachable has its cascade run
  exactly once before `collectgarbage("collect")` returns; a dependent
  already dead when its owner's walk reaches it is skipped. Their relative
  order is undefined (`docs/02-semantics.md`, "Reachability is the
  collector's") and no test asserts it.
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
   `child @ parent` with `child.parent = parent`; drop `parent`; one
   collect: both destructors ran exactly once, compared as a set; the
   parent's reason is `"unreachable"`, the child's `"unreachable"` or
   `"anchor"`, depending on the undefined order.
4. Two unrelated objects, both dropped: one collect runs both
   destructors, compared as a set.
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
- The one-way gate for lifetime values (open question): snapshots stay
  immutable in this task; a value with a dead anchor is refused at
  `attach` with `attempt to anchor to a dead table`.

## Spec issues found

## Review log
