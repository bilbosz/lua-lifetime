---
id: 013
title: Benchmark harness: one process per benchmark file
status: review
depends: [011]
branch: task/013-bench-one-process-per-file
pr:
commits:
review: APPROVE (round 1)
---

## Goal

`bench/run.lua` runs each `bench/bench-*.lua` file in its own interpreter
process, so a benchmark's number no longer depends on which files ran
before it in the same process. Task 002's review (finding F4) measured
`runtime/move` at 25 ns alone and 93 to 109 ns after the transpiler
benchmarks had run in the same luajit process, and `runtime/attach-first`
at 2.0x alone against 1.4x in the full run: LuaJIT's trace cache and the
heap left by earlier files change what later files measure.

## Spec

- `CLAUDE.md`, rule 5: "the cost is measured, not guessed".
- `tasks/002-runtime-anchors-and-cascade.md`, review round 1, F4.
- `bench/README.md`, "The threshold" and the output formats, which must
  stay as task 011 left them.

## Acceptance criteria

- `bench/run.lua` spawns one child process per benchmark file (the same
  interpreter, `--lifetime DIR` and `BENCH_TIME` forwarded) and
  concatenates their stdout lines in file order; a child that fails is
  reported on stderr and the exit status is 1, as a failing `dofile` was.
- A `--in-process` flag keeps the old behaviour for the tests that need
  it; `bench/README.md` says which number to compare and why.
- `make bench` and `make bench BASE=master` are unchanged in their
  outputs' shape; the compare table reads exactly as before.
- `tests/test-bench.lua` covers the per-file spawning (order, forwarding
  of `--lifetime`, a failing file) with a subprocess test.
- `runtime/move` and `runtime/attach-first` under luajit in a full `make
  bench` read within 10% of their numbers when `bench-runtime.lua` runs
  alone; report both.
- `make test` green under both interpreters; `make lint` clean.

## Test cases

1. Two fixture files run in order, each in its own process (a global set
   by the first is absent in the second).
2. `--lifetime DIR` reaches every child.
3. A fixture that raises at load: its name on stderr, the other files'
   lines still printed, exit 1.
4. `make bench` on master twice: no `SLOWER` mark; `runtime/move` within
   10% of its stand-alone number.

## Performance

The instrument; its own time grows by one interpreter start per file
(milliseconds). Nothing under `lifetime/` changes.

## Out of scope

- Changing the median or the threshold.
- CI.

## Spec issues found

## Review log

### Round 1: APPROVE

Suite on `c6765bf`: unit 155/155 under lua5.1 and luajit, conformance 5/5 under both, lint clean (25 files). `make bench` twice: luajit `runtime/move` 25.1 and 25.0 ns against 24.8 to 25.2 stand-alone (within 1%; criterion asked 10%); the old single-process way reproduced at 90 to 101 ns. `make bench BASE=master`: exit 0, no `SLOWER` mark; one single-pairing outlier (`runtime/move` 79.9 ns) traced to a concurrent `make bench` by task 003's implementer, not marked by the two-pairing rule. Traced: a raising file is named on stderr, the other files still run in fresh processes, exit 1; the child is the same interpreter with the same options (`-O0`, `-e`, `-joff`, `-Ohotloop=5`, an interpreter path with a space) verified by hand; temp status files leave nothing behind, with file names and `TMPDIR` containing spaces; `BENCH_FILES`, `BENCH_OUT`, `BENCH_TIME`, `BASE_DIR` and `--lifetime` reach every child; task 011's cases pass unmodified; the five new cases leave nothing behind.

- No findings. Question: if `io.popen` itself fails, the status temp file is left behind (could not be reproduced); worth a `pcall` around the loop some day.
- Noted: a concurrent `make bench` on the same machine still produces single-pairing outliers; two implementers benchmarking at once should expect them. Follow-up candidate: a test that pins the forwarding of interpreter options to the child.
