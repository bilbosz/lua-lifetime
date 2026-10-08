---
name: implement
description: The procedure the implementer follows to complete one task from tasks/ in the lua-lifetime transpiler and runtime: branch, cite spec, write code and tests, run under both interpreters, self-check, commit, hand off. Use at the start of every implementation round.
---

# Implement a task

## Before writing code

1. Read `CLAUDE.md`, the task file, and **every** spec section the task cites.
   Read the surrounding sections too; the sentence you need is often the one
   after the one cited.
2. Read the existing code you will touch and the tests that cover it.
3. If this is a later round, read the reviewer's findings first and make a
   list. Every finding must end up either fixed or answered in the handoff.
4. Write down, in a scratch note, the spec sentence for each acceptance
   criterion. If you cannot find one, stop: record the gap in the task file
   under *Spec issues found* and continue with the criteria you can trace.
   If the criterion touches an entry of `docs/06-open-questions.md`, the
   task is blocked on it; say so and do not pick an answer.

## Branch

- Work on `task/NNN-slug` as named in the task file. Create it from `master`
  if it does not exist. Never commit to `master`; it is only ever changed
  through pull requests opened by the orchestrator.
- Push the branch (`git push -u origin task/NNN-slug`) at the end of every
  round so the reviewer and the eventual pull request see the same commits.
- If `master` has moved since the branch was created and the task is on a
  later round, merge `master` into the branch (no rebase).

## Writing the code

- Follow the technical decisions in `CLAUDE.md`: Lua 5.1 plus `newproxy`,
  no dependencies, hand-written lexer and parser, state inside the object,
  weak dependents lists walked by a numeric loop over the sequence range,
  tombstones, runtime functions bound to locals in generated code.
- Name things after the spec's vocabulary: anchor, dependent, formula,
  dying, dead, tombstone, hook, token, scope record, sentinel, lifetime
  value. A reviewer should be able to grep the spec for any identifier.
- The runtime owns nothing the collector does not. Before adding any table
  the runtime keeps, ask what it references and whether that keeps a user
  object alive; if it does, the design is wrong.
- Write code that runs on both `lua5.1` and `luajit`. `unpack`, not
  `table.unpack`; `loadstring`; no `goto` in generated code unless the
  input had one; no integer division; no `__len` or `__pairs` on tables.
- Correct first, then fast (`CLAUDE.md`, rule 5). Write the version the
  tests prove; then run `make bench`, find the cost on the hot path the
  task's *Performance* section names, and remove what is not forced by
  the spec. Keep every test green while you do. Code that does not use
  the extension must pay nothing: check that the plain-Lua benchmarks did
  not move.
- Where behaviour comes from a specific spec sentence, put a short comment
  with the doc file and heading. Not for every line; for the decision points.

## Tests

Every acceptance criterion gets a test in `tests/test-<module>.lua`,
listed in `tests/run.lua`. For anything involving death:

- assert the **order** of destructions, not just their occurrence (collect
  the log in a table and compare the whole sequence);
- assert the **statement** at which each anchored or scoped death happened
  (interleave log lines with the program's own prints, or check the log
  before and after the statement);
- pin a death by `reachable` with `collectgarbage("collect")`, twice when
  a weak table must have cleared, and never with a timer or a loop; when
  one collection finds several objects, assert that each died exactly
  once, compared as a set, never their relative order, which is undefined;
- include the `reason` argument where the spec defines it.

Conformance tests: if the task adds or changes an `examples/*.lt`, update its
`.expected` file **only** if the task says the expectation changes, and say so
in the commit message.

Run `make test` and `make lint`. Both must be green, and the test output
must show both interpreters when both are installed.

Benchmarks: add or update the benchmarks the task's *Performance* section
names, under `bench/`. Run `make bench` on the branch and on `master` and
keep both outputs for the handoff. If a pre-existing test
fails for reasons outside the task, do not fix it silently: record it in the
handoff.

## Self-check before handing off

Read your own diff as if you were the reviewer, with `/review`'s checklist
open. In particular:

- Pick the spec sentence most likely to be misread in this task and trace one
  concrete program through your code by hand. Does it match?
- Does any runtime table hold a strong reference to a dependent that the
  spec says may be collected? Is there a side table keyed by an anchor?
  Either is a bug.
- Does anything work on one interpreter only?
- Did the change add any cost to code that does not use the feature? Did
  a benchmark the task touches get slower than `master` beyond the
  threshold in `bench/README.md`?
- Is anything in the diff not required by the task? Remove it or justify it in
  the handoff.
- Did you change semantics anywhere? If yes, revert and record the issue.

## Commit

Small commits, each message starting with `[NNN]`. The final commit message of
the round summarises what the round did and cites the spec sections relied on.

## Handoff

Your final message is for a reviewer who has not seen your work. Include:

1. Task id, branch, commit range (`git log --oneline master..HEAD`).
2. What was implemented, by acceptance criterion, each with its spec citation.
3. Test results: the summary line of `make test` for each interpreter, and
   the result of `make lint`. Benchmark results: `make bench` on the branch
   and on `master`, per interpreter, for the benchmarks the task names.
4. What was left out and why, including anything under *Spec issues found*.
5. For later rounds: each reviewer finding and what you did about it.
6. Anything you are unsure about, stated as a question with your current
   choice.
