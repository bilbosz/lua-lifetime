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
make bench BASE=master             # branch and master alternately, compared
BENCH_TIME=0.1 make bench          # shorter runs (noisier); default 0.5 s
make bench INTERPRETERS=luajit     # one interpreter
make bench BENCH_FILES=bench/bench-plain.lua   # some benchmark files only
make bench BENCH_OUT=build/mine    # write the output files there
make bench BASE=old BASE_DIR=../old-checkout   # an existing tree as base
```

`make bench` is not part of `make test`: it is slow (about half a minute
per interpreter today, four times that with `BASE`) and noisy.

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
worktree` (detached, recreated on every run) and runs the **branch's**
benchmark files and input files on the **base's** `lifetime/` too (so a
benchmark the branch adds still gets a base number). Per interpreter it
runs four `bench/run.lua` processes in alternation, branch, base, branch,
base, so a slow stretch of the machine falls on both sides; each
branch-then-base pair is a *pairing*. The runs write
`build/bench-<interpreter>-1.txt`, `build/bench-base-<interpreter>-1.txt`,
`build/bench-<interpreter>-2.txt` and `build/bench-base-<interpreter>-2.txt`
(in the format above; `build/bench-<interpreter>.txt` is only written
without `BASE`), and `bench/compare.lua` prints, and writes to
`build/bench-compare-<interpreter>.txt`:

```
name<TAB>branch ns/op<TAB>base ns/op<TAB>pairing 1<TAB>pairing 2<TAB>branch/base<TAB>mark
```

`branch ns/op` and `base ns/op` are the medians of each side's two runs;
`pairing 1` and `pairing 2` are branch/base within each pairing;
`branch/base` is the ratio of the two medians. Above 1.0 means the branch
is slower. `mark` is `SLOWER` when **both** pairings are beyond the
threshold below. A benchmark the base cannot run (it uses something the
base's runtime does not have) is reported on standard error by the base
run and gets `-` for that pairing, and `-` for `branch/base` unless both
pairings have it; it is never marked.

`BASE_DIR=<dir>` compares with a tree that already exists instead of
checking `BASE` out (the tree is used as it is and never removed; `BASE`
then only names it). `BENCH_FILES` restricts every run to the given
benchmark files; `BENCH_OUT` puts the output files in another directory
(the tests use both).

The exit status of `make bench` is 1 when a branch run fails (a benchmark
file or a benchmark raised), when a base run prints no benchmark line at
all (the base's `lifetime/` is missing or cannot load anything; the
message names the interpreter and the pairing, and that interpreter's
comparison is skipped), or when `bench/compare.lua` fails. A base run that
fails only some benchmark files passes: those benchmarks get `-` as above
and the base run's errors stay on standard error.

## The threshold

A benchmark is a **finding** when it is more than 10% slower than base
**in both pairings** of one `make bench BASE=master` on the same machine:
`pairing 1` and `pairing 2` both above 1.10. `bench/compare.lua` applies
this two-run rule and marks such a benchmark `SLOWER`; a benchmark with
one pairing above 1.10 and the other not is noise and is not marked, even
when `branch/base` is above 1.10. The reviewer reads the mark
(`.claude/skills/review/SKILL.md`, "Performance"); the threshold is
`bench.THRESHOLD` in `bench/lib/bench.lua`.

Beyond the threshold, the plain-Lua benchmarks (`plain/*`) must also keep
their `ratio` at 1.0 within noise: code that does not use the extension
pays nothing. Read that `ratio` in `build/bench-<interpreter>*.txt`, not
`branch/base`: it compares the transpiled chunk with plain Lua inside one
process, timed runs interleaved, and is the trustworthy number for the
"free" benchmarks.

How large the noise is. It is between processes, not within one: on the
machine where tasks 010 and 011 were written, `branch/base` for
**identical** code (a branch whose `lifetime/` matched `master` up to
comments) ranged from **0.90 to 1.10** across separate `bench/run.lua`
processes (task 010's review), while the in-process interleaved `ratio`
of `plain/transpiled` stayed **within 3%** of 1.0. Task 011's two
invocations of `make bench BASE=master` on identical `lifetime/` (sixteen
processes) agree, with one outlier each way: one pairing of
`build/generated-5000` under luajit read 1.143 while the other pairing of
the same invocation read 0.988 (not marked), and one `plain/transpiled`
`ratio` read 0.957 among fifteen between 0.984 and 1.018. That is why
`make bench BASE=` alternates processes and asks both pairings to agree
rather than timing more runs in one process: a single pairing beyond
1.10 says nothing, two do.

## The benchmarks

| Name | File | Measures | Baseline |
| --- | --- | --- | --- |
| `build/plain.lt` | `bench-build.lua` | `cli.build` on `examples/plain.lt` | `loadstring` of the same text |
| `build/generated-5000` | `bench-build.lua` | `cli.build` on a generated 5 000-line plain Lua file | `loadstring` of the same text |
| `build/lifetime-largest` | `bench-build.lua` | `cli.build` on the largest file under `lifetime/` (today `lifetime/parser.lua`); cited by the `jit.off` comments in `lifetime/parser.lua` and `lifetime/emit.lua` | `loadstring` of the same text |
| `plain/transpiled` | `bench-plain.lua` | running the transpiled output of `bench/plain/workload.lua` | running the same source loaded directly; ratio 1.0 within noise |

## Adding a benchmark

A task that touches a hot path adds or updates a benchmark here (its
*Performance* section names it). Put it in a `bench/bench-<area>.lua`
file, name it `<area>/<what>`, give it the plain-Lua baseline that does
the same work by hand, and add a row to the table above. Read input files
relative to the repository root, so a base run reads the same input.
