---
id: 020
title: Runtime: `lifetime.dying(x)`, the dying-phase query, for a hook on several anchors
status: done
depends: [019]
branch: task/020-dying
pr:
commits:
review:
---

## Goal

A program can ask the runtime whether an object is dying: its death
decided by a cascade and its tombstone not yet made. `lifetime.dying(x)`
is `true` inside `x`'s own destructor, inside a hook on `x`, and inside
the destructor of anything else in the same cascade, and `false`
otherwise. A hook on two anchors, `(form, input)`, can then tell whether
the form it would unlink the input from is going too, which the
lua-lifetime branch of Treflove did with a flag the form's destructor set
by hand.

## Spec

- `docs/02-semantics.md`, "Tombstones and `lifetime.alive`": the
  `lifetime.dying(x)` bullet ("`true` from the moment a cascade has
  decided `x`'s death until `x` is a tombstone"; "`false` for a live
  object, for a tombstone ..., for a block's record outside its exit, and
  for `nil` or `false`"; the error text) and "A **dying** object is not
  dead ... `lifetime.dying(x)` reads the phase."
- `docs/02-semantics.md`, "Hooks: the `!@` operator": "A hook on several
  anchors can ask `lifetime.dying(a)` whether `a` is in the cascade that
  runs it."
- `docs/02-semantics.md`, "Cascading death": the decide phase marks every
  object of the cascade before any body runs, so `dying` is `true` for
  all of them from the first body on.
- `docs/02-semantics.md`, "The `lifetime` table": the row for
  `lifetime.dying(x)`.
- `docs/03-runtime.md`, "The state of an object": "`lifetime.dying(x)`
  reads `"dying"` ... one field read each."
- `docs/05-decisions.md`, "`lifetime.dying` reads the dying phase".

## Acceptance criteria

- `lifetime.dying(x)` is `false` for a live object, `true` inside its
  `__destroy`, inside a hook on it and inside the `__destroy` of another
  object of the same cascade (before and after `x`'s own body), and
  `false` once `x` is a tombstone, where `lifetime.alive(x)` is `false`.
- `lifetime.dying` of a token is `true` inside a hook on it; of a block's
  record `true` inside a hook on the record during the exit and `false`
  inside the block's function.
- `lifetime.dying(nil)`, `lifetime.dying(false)`, a lifetime value, the
  `lifetime.scope` marker, a table the runtime never saw and a plain
  function are `false`; `lifetime.dying(5)` is `bad argument #1 to
  'lifetime.dying' (object expected, got number)`.
- A hook on `(form, input)` that unlinks the input unless
  `lifetime.dying(form)` unlinks when the input dies first, does nothing
  when the form dies first, and does nothing when both die in one
  cascade.
- `lifetime/init.d.tl` and `editor/luals/meta/lifetime.lua` declare it.
- `make test` green under `lua5.1` and `luajit`; `make lint` clean.

## Test cases

`tests/test-runtime.lua`, suite "dying": `a` with dependent `b`,
`destroy(a)` logs `a (destroy)`, `b (anchor)`, and the bodies see
`dying(a)`, `dying(b)` both `true` in each (with `alive(b)` `true` in
`a`'s); before the statement both `false`, after it both `false` and
`alive(a)` `false`. The form/input idiom in three cases, the whole log
asserted: `input (destroy)`, `unlink input from form`; `form (destroy)`,
`form going: nothing to unlink`; and `form (anchor)`, `form going:
nothing to unlink`, `input (anchor)` from `destroy(period)` with `form @
period` and `input @ form`. A token under a hook; a block's record inside
and outside its exit; the non-object cases and the error text. The
sentence most likely to be misread is "from the moment a cascade has
decided `x`'s death": `dying(b)` is already `true` inside `a`'s body,
before `b`'s own body has run; the first case covers it.

## Performance

None: `lifetime.dying` is a query off every hot path, one `rawget` and
one field read, and nothing else in the runtime changed. Code that does
not call it pays nothing.

## Out of scope

- The anchor argument to hooks and `__destroy`
  (`docs/06-open-questions.md`, "Whether a hook or destructor learns
  which anchor died") stays open.
- Any change to what `lifetime.alive` reports.

## Spec issues found

None.

## Review log

Spec change and implementation in one task branch, as task 019 was done
(the Treflove comparison branch needed both in one sitting); the decision
is recorded in `docs/05-decisions.md`. Self-checked: `make test` under
`lua5.1` and `luajit`, `make lint`, `make luals-check`.
