---
id: 011
title: Benchmark harness: bake the two-run rule into `make bench BASE=`, base exit status, README noise range
status: review
depends: [010]
branch: task/011-bench-two-run-rule
pr: https://github.com/bilbosz/lua-lifetime/pull/12
commits:
review: APPROVE (round 2)
---

## Goal

`make bench BASE=<ref>` becomes the instrument the reviewer can trust on a
noisy machine: it runs branch and base alternately (A B A B) per
interpreter, reports the ratio of the medians over both pairings, and
marks `SLOWER` only when both pairings exceed the threshold, so the
two-run rule of `bench/README.md` is applied by the tool rather than by
the reader. A base run that fails is visible in the exit status. The
README states the noise actually observed. Created from the two
non-blocking findings of task 010's review (F1, F2) and the reviewer's
note on alternation.

## Spec

- `CLAUDE.md`, rule 5: "the cost is measured, not guessed … `make bench`
  … compares the branch with `master` on the same machine."
- `tasks/010-benchmark-harness.md`, *Performance*: "its noise does: the
  median of several runs and the two-run rule exist so that the
  reviewer's threshold is not tripped by a busy machine."
- `tasks/010-benchmark-harness.md`, review round 1, F1 and F2, and the
  reviewer's note: cross-process branch/base for identical code ranged
  0.90 to 1.10 on this machine while the in-process interleaved ratio
  stayed within 3%; the noise is between processes, not within one, so
  the lever is alternation, not more runs per process.
- `.claude/skills/review/SKILL.md`, "Performance": the reviewer compares
  with `master` against the threshold in `bench/README.md`.

## Acceptance criteria

- `make bench BASE=<ref>` runs, per interpreter found, branch, base,
  branch, base (four `bench/run.lua` processes), writing
  `build/bench-<interp>-1.txt`, `build/bench-base-<interp>-1.txt`,
  `build/bench-<interp>-2.txt`, `build/bench-base-<interp>-2.txt`;
  `make bench` without `BASE` is unchanged (one run per interpreter).
- `bench/compare.lua` takes the two pairings, prints per benchmark the
  ratio branch/base of each pairing and the ratio of the medians over
  both, and marks `SLOWER` only when both pairings exceed
  `bench.THRESHOLD`; a benchmark the base cannot run prints `-` and is
  never marked.
- The exit status of every `bench/run.lua` process reaches `make`: a
  branch run that fails fails `make bench`; a base run that produces no
  benchmark line at all fails `make bench BASE=`; a base run that fails
  only some benchmark files passes with `-` for those, as the README
  says, and the failure lines stay on stderr.
- `bench/README.md`, "The threshold": the observed cross-process range
  (0.90 to 1.10 for identical code), the in-process interleaved `ratio`
  (within 3%) as the trustworthy number for the `plain/*` "free"
  benchmarks, and the rule as the tool now applies it.
- `tests/test-bench.lua` covers `compare` with two pairings (both over,
  one over, neither over, a `-` on one side) and the exit-status rule for
  a base with no lines.
- `make test` green under both interpreters; `make lint` clean.

## Test cases

1. Two pairings 1.12 and 1.13: marked `SLOWER`, median ratio 1.125.
2. Pairings 1.12 and 1.04: not marked; the line shows both.
3. Base missing a benchmark in one pairing: `-` for that pairing, not
   marked.
4. A base run with an empty output file: `make bench BASE=` exits 1 with a
   message naming the interpreter; checked by a subprocess test that
   points `BASE_DIR` at a directory without `lifetime/`.
5. `make bench BASE=master` on a branch identical to `master` in
   `lifetime/`: no mark in two consecutive invocations.

## Performance

The instrument's own time doubles under `BASE=` (about three minutes for
both interpreters); acceptable, it is not part of `make test`. No code
under `lifetime/` changes; `make bench BASE=master` must show every
benchmark within the threshold.

## Out of scope

- `min` instead of `median` (a change to task 010's wording; decide
  separately if the noise stays a problem).
- CI integration.
- Any benchmark of the runtime or the emitter: tasks 002 to 006.

## Spec issues found

## Review log

### Round 1: REQUEST_CHANGES

Suite on `6188b63`: unit 70/70 under lua5.1 and luajit, conformance 5/5 under both, lint clean (23 files). `make bench BASE=master` twice by the reviewer (base `eb17aa6`, identical `lifetime/`): no `SLOWER` mark; cross-process pairings on identical code spanned 0.903 to 1.089; in-process `plain/transpiled` ratio 0.941 to 1.020. Exit-status paths reproduced under dash and bash: failing branch run, base with no line (pairing 1 and pairing 2), base failing some files, failing `compare.lua`.

- F1 (blocking): `lua5.1 tests/run.lua unit` without `make` on PATH fails 4 cases (`make: not found`, status 127) instead of skipping them. Fix: probe `command -v make` once before the "make bench" suite; if absent, print one line and do not register the four cases.
- Orchestrator's answers 1 to 3 confirmed correct in code: exit 2 asserted with the message; `-` for the median ratio unless both pairings complete; the rest of an interpreter skipped after an empty base run.
- `BASE_DIR` safety traced: the only `rm -rf` is reachable solely for the literal `build/base`. Subprocess tests leave nothing outside `build/test-bench/` and create no worktree.
- Nit: `Makefile`, `bench_to`'s `return $$code` returns 0 if the status file vanished; `return $${code:-1}`.
- Orchestrator's decision on the reviewer's question: a `SLOWER` mark in one invocation is a finding to confirm, not yet a finding; the README states that a mark must appear in two consecutive invocations to count (a mark in one of two is noise), given that both pairings above 1.10 on identical code is a percent-level event per benchmark per invocation. The in-process range is stated as "within 3%, with occasional outliers to 0.94".

### Round 2: APPROVE

Suite on `73f098c`: unit 70/70 under lua5.1 and luajit, conformance 5/5 under both, lint clean (23 files). Without `make` on PATH (standard tools present) both interpreters print the one skip line and report 66/66, exit 0; the suite is not registered, nothing counted as passed. `bench_to`'s default checked in isolation under dash and bash: a missing status file now returns 1, a killed command its signal status. `make bench BASE=master` not re-run: the only change on that path alters nothing when the status file exists; round 1's two invocations stand.

- F1 fixed in `73f098c` as specified. The README states the confirmation rule as decided: a `SLOWER` mark counts when the same benchmark is marked in two consecutive invocations; one of two is noise; in-process ratio within 3% with occasional outliers to 0.94. `bench.THRESHOLD`'s comment says the same.
- Later notes: `tests/test-harness.lua` and `tests/test-emit.lua` list files through the shell, so a PATH with literally only the interpreters fails two pre-existing cases (not this task's); `.claude/skills/review/SKILL.md`, "Performance", could point at the confirmation rule in `bench/README.md` (a `chore/` edit).
