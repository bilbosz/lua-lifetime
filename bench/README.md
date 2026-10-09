# Benchmarks

Performance is a priority second only to the spec and ownership order
(`CLAUDE.md`, rule 5; `docs/05-decisions.md`, "Performance is a priority,
second only to correctness"): the cost of the extension is measured, not
guessed. `docs/03-runtime.md`, "Performance", lists what must be free, what
is cheap and what is forced; each line is something a benchmark here
measures against plain Lua doing the same work by hand.

## Running

```
make bench                         # every benchmark, every interpreter found
make bench BASE=master             # the same, plus the comparison with master
BENCH_TIME=0.1 make bench          # shorter runs (noisier); default 0.5 s
make bench INTERPRETERS=luajit     # one interpreter
```

`make bench` is not part of `make test`: it is slow (about half a minute
per interpreter today, twice that with `BASE`) and noisy.

## How a benchmark is measured

A benchmark is a function; one call is one operation. `bench/run.lua`
loads every `bench/bench-*.lua`, and each registers its benchmarks with
`bench.add(name, fn, {baseline = fn2})` (`bench/lib/bench.lua`). For each
benchmark the harness

1. warms up `fn` (and the baseline) by calling it in doubling batches until
   one batch takes a twentieth of the budget, which is also the batch size
   of the timed runs;
2. times five runs of `fn`, each spending the budget (`BENCH_TIME`
   seconds of `os.clock`, default 0.5) in whole batches, after a full
   collection; the baseline's runs are interleaved with `fn`'s, so a busy
   moment of the machine hits both;
3. reports the median of the five runs in ns per operation, and the ratio
   median(`fn`) / median(baseline).

The clock is `os.clock`, the process's CPU time: Lua 5.1 has no
sub-second wall clock, and for a single-threaded benchmark that does no
I/O the two advance together, CPU time without the moments the process
was descheduled.

## Reading the output

`make bench` prints, and writes to `build/bench-<interpreter>.txt`, one
line per benchmark:

```
name<TAB>ns/op<TAB>ratio
```

`ratio` is the cost relative to the benchmark's plain-Lua baseline, `-`
when it has none. The baseline says what the ratio means; each
`bench-*.lua` file states it at the top. A ratio of 1.0 means the
extension costs nothing over plain Lua; that is the target of every
benchmark of the "free" list.

`make bench BASE=<ref>` checks `<ref>` out into `build/base/` with `git
worktree` (detached, recreated on every run), runs the **branch's**
benchmark files and input files on the **base's** `lifetime/` (so a
benchmark the branch adds still gets a base number), writes
`build/bench-base-<interpreter>.txt`, and prints, and writes to
`build/bench-compare-<interpreter>.txt`:

```
name<TAB>branch ns/op<TAB>base ns/op<TAB>branch/base<TAB>mark
```

`branch/base` above 1.0 means the branch is slower. `mark` is `SLOWER`
when the ratio is beyond the threshold below. A benchmark the base cannot
run (it uses something the base's runtime does not have) is reported on
standard error and gets `-` for base and ratio.

## The threshold

A benchmark is a **finding** when it is more than 10% slower than base
(`branch/base` above 1.10, marked `SLOWER`) **on both of two consecutive
runs** of `make bench BASE=master` on the same machine. One `SLOWER` mark
alone is noise until the second run confirms it. The reviewer applies this
rule (`.claude/skills/review/SKILL.md`, "Performance"); the threshold is
`bench.THRESHOLD` in `bench/lib/bench.lua`.

Beyond the threshold, the plain-Lua benchmarks (`plain/*`) must also keep
their `ratio` at 1.0 within noise: code that does not use the extension
pays nothing.

How large the noise is: on the machine where task 010 was written, a
branch whose `lifetime/` differed from `master` only in comments read
`branch/base` between 0.93 and 1.10 over three runs of `make bench
BASE=master`, none beyond the threshold, and six alternating runs of
`build/generated-5000` (about 2 operations per timed run) spread over
±5%. A single reading near 1.10 says nothing; two in a row do.

## The benchmarks

| Name | File | Measures | Baseline |
| --- | --- | --- | --- |
| `build/plain.lt` | `bench-build.lua` | `cli.build` on `examples/plain.lt` | `loadstring` of the same text |
| `build/generated-5000` | `bench-build.lua` | `cli.build` on a generated 5 000-line plain Lua file | `loadstring` of the same text |
| `build/lifetime-largest` | `bench-build.lua` | `cli.build` on the largest file under `lifetime/` (today `lifetime/parser.lua`); cited by the `jit.off` comments in `lifetime/parser.lua` and `lifetime/emit.lua` | `loadstring` of the same text |
| `parse/lifetime-largest` | `bench-build.lua` | the lexer and the parser alone on the same file as `build/lifetime-largest` (task 005) | `loadstring` of the same text |
| `parse/extension-5000` | `bench-build.lua` | the lexer and the parser on a generated 5 000-line file that uses `@`, the list form, `!@` and `lifetime.scope` on most lines (task 005); a base without the extension cannot run it | `loadstring` of the same file with the extension left out |
| `plain/transpiled` | `bench-plain.lua` | running the transpiled output of `bench/plain/workload.lua` | running the same source loaded directly; ratio 1.0 within noise |

## Adding a benchmark

A task that touches a hot path adds or updates a benchmark here (its
*Performance* section names it). Put it in a `bench/bench-<area>.lua`
file, name it `<area>/<what>`, give it the plain-Lua baseline that does
the same work by hand, and add a row to the table above. Read input files
relative to the repository root, so a base run reads the same input.
