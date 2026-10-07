---
id: 008
title: Port the conformance examples from `xd/examples/`; document each deviation in `docs/07-conformance.md`
status: todo
depends: [004, 007]
branch:
pr:
commits:
review:
---

## Goal

Every program in `xd/examples/` (listed in `docs/07-conformance.md`,
"Examples to classify") exists as `examples/NAME.lt` with
`examples/NAME.lt.expected`, classified under one of the three headings of
`docs/07-conformance.md`, and passes under both interpreters. The `xd`
repository is read, not written: the `.xd` sources are the input, and
where `xd` has not yet rewritten an example under its own `/spec-change`
pass, this task writes the lua-lifetime `.expected` and records the
difference as a deviation.

## Spec

- `docs/07-conformance.md`, "The rule": the three headings and what goes
  under each; "Every ported example must pass under every interpreter the
  runner finds. There is no expected-failure marker."
- `docs/02-semantics.md`, every section, as the behaviour each example
  shows; in particular "Cascading death" (order reversed from `xd`),
  "Tombstones" (not `nil`), "Reachability is the collector's"
  (`collectgarbage`), "`__destroy` and reasons" (no `remaining`).
- `examples/README.md`: the `.expected` contract.
- `CLAUDE.md`, rule 2: never edit an `.expected` to make a test pass unless
  the spec says the old expectation was wrong, and say so in the commit.

## Acceptance criteria

- One `examples/NAME.lt` and `.expected` per `xd` example, same `NAME`.
- Each example's header comment names its heading (ported unchanged,
  rewritten around `collectgarbage`, deviation) and, for a deviation, the
  decision of file 10 that causes it.
- `docs/07-conformance.md` lists every example under its heading, with
  the note the heading asks for; the "Examples to classify" list is empty.
- Examples that use removed features (`lifetime.all`, `lifetime.any`,
  `lifetime.scope()`, `lifetime.scope(2)`, `remaining`, `lifetime.kind`,
  `lifetime.anchor`, `type(h) == "hook"`, dead references read as `nil`)
  are rewritten to the lua-lifetime spelling or classified as deviations;
  `shared_channel` and `workers` (which need `any`) are deviations with
  the token-plus-counting-hook idiom of decision 7 or are marked
  "not portable" in the table with the reason.
- Examples that pin a reachable death to a statement insert
  `collectgarbage("collect")` where `docs/07-conformance.md` says.
- Every example passes under both interpreters; `make test` green; `make
  lint` clean.

## Test cases

The examples are the tests. Three to trace by hand in the handoff:

1. `release_chain`: under decision 10 the order is `connection`'s body
   first, then `data_rp`, then `login`'s body, `logout_rp`, `login_rp`,
   then `session`'s body; and `conn.session` inside `Connection:release`
   is alive, so the nested `release()` call now works (lesson 4
   reversed). The `.expected` differs from `xd`'s: a deviation.
2. `defer`: block 2's hook runs after `conn`'s `__destroy`; block 3 cannot
   decode `remaining` and prints the reason only; block 4's `print(rollback,
   keep ~= nil)` prints a tombstone, not `nil`.
3. `cache_drop` or `dead_cache`: whichever pins a reachable death gets a
   `collectgarbage("collect")`, and the weak-table check collects twice.

The sentence most likely to be misread: "Any example it cannot honour is a
documented deviation … not a changed expectation" in `xd`. The `xd`
`.expected` files are never edited from here; the lua-lifetime
`.expected` is written fresh and the difference documented.

## Performance

Hot path: none new. The ported examples are not benchmarks; do not
optimise for them. If an example shows a cost the benchmarks miss, note
it for a follow-up task.

## Out of scope

- Writing to the `xd` repository.
- New examples beyond the `xd` set (tasks 006 and 007 added theirs).
- Settling any open question an example touches: classify it as a
  deviation and note the question.

## Spec issues found

## Review log
