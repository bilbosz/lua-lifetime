---
id: 010
title: Benchmark harness: `make bench`, comparison with plain Lua and with `master`
status: todo
depends: [001]
branch:
pr:
commits:
review:
---

## Goal

`make bench` runs every benchmark under `bench/` under every interpreter
found and prints, per benchmark, the time per operation and the ratio to
its plain-Lua baseline; `make bench BASE=master` also runs the same
benchmarks on `master` (checked out into `build/base/`) and prints the
ratio branch/base. Later tasks add their benchmarks to it; this task adds
the harness, the threshold, and the benchmarks for what exists after task
001.

## Spec

- `CLAUDE.md`, rule 5: "Performance is a priority, second only to
  correctness … the cost is measured, not guessed: a task that touches a
  hot path adds or updates a benchmark under `bench/`, and `make bench` …
  compares the branch with `master` on the same machine."
- `docs/03-runtime.md`, "Performance": the free, cheap and forced lists;
  every line is something a benchmark will measure.
- `docs/05-decisions.md`, "Performance is a priority, second only to
  correctness".
- `.claude/skills/review/SKILL.md`, "Performance": the reviewer compares
  with `master` against the threshold in `bench/README.md`.

## Acceptance criteria

- `bench/lib/bench.lua`: a zero-dependency harness. `bench.add(name, fn,
  {baseline = fn2})` registers a benchmark; each is warmed up, then run
  for a fixed wall-clock budget (default 0.5 s, `BENCH_TIME` overrides),
  and reported as ns per operation (median of 5 runs) and, when a
  baseline is given, the ratio to the baseline.
- `bench/run.lua` loads every `bench/bench-*.lua` and runs them; output is
  one line per benchmark, stable and parseable: `name<TAB>ns/op<TAB>ratio`.
- `make bench` runs `bench/run.lua` under every interpreter found and
  writes `build/bench-<interpreter>.txt`. `make bench BASE=<ref>` checks
  out `<ref>` into `build/base/` with `git worktree`, runs the same
  benchmark files (the branch's, so new benchmarks have a base number) on
  the base's `lifetime/`, and prints the ratio branch/base per benchmark,
  marking each beyond the threshold.
- `bench/README.md` states the threshold (start: a benchmark is a finding
  when it is more than 10% slower than base on both of two consecutive
  runs) and how to read the output.
- First benchmarks, `bench/bench-build.lua`: `cli.build` on
  `examples/plain.lt` and on a generated 5 000-line plain Lua file; and
  `bench/bench-plain.lua`: the transpiled output of plain Lua against the
  same source loaded directly (ratio must be 1.0 within noise, the "free"
  rule).
- `make bench` is not part of `make test` (it is slow and noisy); `make
  lint` covers `bench/`.
- `bench/bench-build.lua` also measures `cli.build` on the largest file
  under `lifetime/` (today `lifetime/parser.lua`); this is the transpiler
  benchmark that the `jit.off(true, true)` comments in
  `lifetime/parser.lua` and `lifetime/emit.lua` cite, so update those
  comments to name it (task 001, review finding F2). Baselines from task
  001's review: lua5.1 7.5 to 7.8 ms, luajit 3.6 to 3.7 ms steady, 27 ms
  under luajit without `jit.off`.

## Test cases

- `tests/test-bench.lua`: the harness's median and ratio on fake timings
  (inject a clock), and the output line format.
- `make bench` on a clean checkout prints a line for each benchmark under
  each interpreter found; `make bench BASE=master` on `master` itself
  prints ratios within the threshold.

The sentence most likely to be misread: "compares the branch with `master`
on the same machine". The base run uses the branch's benchmark files with
the base's runtime and transpiler, so a benchmark added by the branch has
a base number to compare against; it does not run `master`'s own
`bench/`.

## Performance

This task is the measuring instrument. Its own cost does not matter; its
noise does: the median of several runs and the two-run rule exist so that
the reviewer's threshold is not tripped by a busy machine.

## Out of scope

- Benchmarks for the runtime and the emitter: tasks 002 to 006 add them.
- Any optimisation.
- CI integration.

## Spec issues found

## Review log
