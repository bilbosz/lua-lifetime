---
id: 008
title: Port the conformance examples from `xd/examples/`; document each deviation in `docs/07-conformance.md`
status: done
depends: [004, 007]
branch: task/008-port-conformance-examples
pr: https://github.com/bilbosz/lua-lifetime/pull/30
commits: ac7fbade0701d4d9f4aea10da2e26e8bb52d3c11
review: APPROVE (round 1)
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

1. **Test case 1 lists `release_chain`'s order against the spec.** It
   reads "`connection`'s body first, then `data_rp`, then `login`'s body,
   `logout_rp`, `login_rp`, then `session`'s body". `docs/02-semantics.md`,
   "Cascading death", step 2, runs each dying object's own body before its
   dependents, and `data_rp` and `login` are the session's dependents, so
   the session's body comes right after the connection's:
   connection, session, `data_rp`, login, `logout_rp`, `login_rp`. The
   port follows the spec; the task text needs no other change.
2. **A collect nested in a pending call does not see a dropped object on
   LuaJIT.** Under LuaJIT (GC64), `print(pcall(function() g = nil;
   collectgarbage("collect") end))` did not finalize `g`: the main chunk's
   frame keeps the argument slots of the call it is building (`print`'s
   frame-link slot still held `g` from the earlier `@` call), and Lua
   counts stack slots as references. A `collectgarbage("collect")` that is
   a statement of its own, in the frame that dropped the reference,
   overwrites those slots and is reliable on both interpreters. This is
   the host's reachability, not a runtime bug (02, "Reachability is the
   collector's"), but "`collectgarbage("collect")` is the deterministic
   point" could say so for test authors; every port puts the collect on a
   statement of its own, and `destroy_errors.lt` explains why. Proposed as
   a note for 02 or 07 through `/spec-change`, not made here.
3. **Ports that wait for task 012.** `scope_passing` and part 3 of
   `dead_reference` anchor a function in `xd`; a function cannot be an
   anchored dependent until task 012, so the ports use a table with
   `__call`. After task 012 `scope_passing` could return a closure again;
   `dead_reference` part 3 would still need the table, since a call on a
   dead function is not caught (`docs/06-open-questions.md`,
   "Non-table dependents after death").
4. **Two examples renamed to free their names.** Tasks 006 and 007 wrote
   `examples/block_exits.lt` and `examples/uncaught_error.lt`, which are
   the names of two `xd` examples and differ materially from them. Their
   content is kept as `exit_paths.lt` and `main_scope_error.lt` (task
   006's test case 2 and task 007's test case 2; `tests/test-cli.lua`
   follows the rename), and the names hold the `xd` ports. Task files 006
   and 007 still name the old files; they are history and were not edited.
5. **On the error path a scope's dependents can die by the collector
   before the catch site unwinds them.** Found by running every example
   with `LUA_INIT='collectgarbage("setpause", 10);
   collectgarbage("setstepmul", 1000)'`: under Lua 5.1 the existing
   `examples/unwind.lt` (task 006) printed `destroy a (unreachable)`
   before `destroy b (anchor)` instead of `b`, then `a` with `"anchor"`.
   When the runtime's `pcall` unwinds at the catch site, the frames
   between the raise and the catch are gone, the records hold their
   dependents weakly (the implicit `reachable` term, decision 4), and the
   first destructor that allocates can let the collector finish a cycle
   and finalize a dependent of an outer record first. 02, "Scopes:
   `lifetime.scope`", promises the unwinding order ("die innermost first,
   each in its own reverse attachment order"); "Reachability is the
   collector's" allows the earlier death. With the default collector
   settings every example passes on both interpreters, and a given
   interpreter build allocates the same way on every run, so the suite is
   stable; but the two sentences disagree, and the ports that raise
   through a scope with more than one destructor to run (`block_exits`
   part 4, `uncaught_error`) depend on it as `unwind.lt` does; a hook is
   pinned and is not exposed.
   Not settled here: a runtime fix (keeping the unwound records'
   dependents strongly referenced from the raise to the catch, which Lua
   5.1 gives no hook for, or stopping the collector while unwinding) or a
   sentence in 02 is a `/spec-change` for the human. The same window made
   `uncaught_error`'s `log`, a main-chunk local in `xd`, die
   `"unreachable"` during the unwinding; the port makes it a global
   (docs/07-conformance.md, its row), which removes that case.

## Review log

### Round 1: APPROVE

Head `0b6c774`. `make test`: 301/301 under `lua5.1` and `luajit`,
conformance 75/75 under both; `make lint` clean; `make bench` not
applicable (no runtime, transpiler or harness code changed). No `xd`
file changed. Every heading-1 and heading-2 `.expected` is `xd`'s byte
for byte apart from the chunk name in `!error:` lines; every deviation
row's "what differs" matches the diff and cites a decision that causes
it. Two programs beyond the examples were run by the reviewer (nested
cleanup inside an owner's body; `last_of` with the token destroyed before
its anchors), identical on both interpreters.

- F1 (non-blocking): heading 1 holds two ports whose programs changed
  beyond spelling (`block_exits` part 3 guards a `goto` program with
  `jit`; `uncaught_error` registers `log` as a global with
  `@ lifetime.reachable`), while the `dead_cache` ruling put a program
  change under Deviations. Orchestrator: the ports stay; heading 1's
  sentence in `docs/07-conformance.md` is amended in the done chore to
  say the criterion is the byte-identical `.expected`, the program may
  need the host's spelling.
- Orchestrator rulings: test case 1's order for `release_chain` was the
  task text's error, the spec ("Cascading death") wins; `dead_cache` is
  a deviation because its program changed; the `caller` "not ported" row
  satisfies the one-file-per-example criterion.
- Spec issue 5 (a scope's dependents collected before the catch site
  unwinds them, reproduced by the reviewer under GC stress on `lua5.1`,
  `unwind.lt` only) is settled by the human: the runtime unwinds at the
  raise point (`spec/unwind-at-raise`, task 014). Spec issue 2 (a collect
  nested in a pending call's argument list on LuaJIT) becomes a note in
  02 in the done chore. Spec issue 3: revisit `scope_passing` after task
  012.
