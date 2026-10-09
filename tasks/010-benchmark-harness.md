---
id: 010
title: Benchmark harness: `make bench`, comparison with plain Lua and with `master`
status: review
depends: [001]
branch: task/010-benchmark-harness
pr: https://github.com/bilbosz/lua-lifetime/pull/9
commits:
review: APPROVE (round 1)
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

- (implementer, round 1; not a semantic issue, a wording one) The first
  criterion says "a fixed wall-clock budget". Lua 5.1 has no sub-second
  wall clock without a dependency (`os.time` has a resolution of one
  second; LuaJIT's `ffi` is not in Lua 5.1), so the harness times with
  `os.clock`, the process's CPU time, which for a single-threaded
  benchmark without I/O advances with the wall clock and leaves out the
  moments the process is descheduled. Stated in `bench/README.md` and
  `bench/lib/bench.lua`; the clock is injectable (`options.clock`) if a
  human prefers another.

## Review log

### Round 1: APPROVE

Suite on `eaa2933`: unit 61/61 under lua5.1 and luajit, conformance 5/5 under both, lint clean (23 files, `bench/` included). `make bench BASE=master` twice (base `51d071c`): no `SLOWER` mark; `plain/transpiled` in-process ratio 0.97 to 1.02 under both interpreters, the "free" rule holds; `build/lifetime-largest` 7.15 to 7.59 ms lua5.1, 3.87 to 4.07 ms luajit, consistent with task 001's baselines; `make clean` removes `build/` and prunes the worktree.

- Traced: `--lifetime DIR` isolates the base's `lifetime/` (loader ahead of the path searcher, a missing module raises, never falls through to `./lifetime/`); the base run uses the branch's benchmark files and inputs; median of 5 with interleaved baseline runs; `bench-plain` times the loaded chunk functions, not `loadstring`. The `jit.off` comments' numbers reproduce (28.5 ms without, 3.9 ms with).
- Orchestrator's decision on the spec issue: `os.clock` (process CPU time) satisfies "a fixed wall-clock budget"; stated in the README.
- F1 (non-blocking): `make bench BASE=` ignores the exit status of the base run and of `compare.lua`; a base that cannot load a benchmark file exits 0. Follow-up task 011.
- F2 (non-blocking): the README's noise range is narrower than observed: cross-process branch/base for identical code ranged 0.90 to 1.10, in-process interleaved ratio within ±3%. Follow-up task 011 (and the reviewer's suggestion to alternate branch and base runs, A B A B, and mark `SLOWER` only when both pairings exceed the threshold).
- Noted for task 005: `jit.off` costs about 25% on small inputs under luajit while saving 7x on `lifetime/parser.lua`; the lexer is superlinear on `generated-5000`.
