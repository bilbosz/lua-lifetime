---
id: 021
title: The runtime as a library: `lifetime.attach(obj, a1, …)`, `lifetime.hook(f, a1, …)`, `lifetime.named_hook` and `lifetime.block` for programs that are not transpiled
status: review
depends: [018]
branch: task/021-library-form
pr:
commits:
review: APPROVE (round 3)
---

## Goal

A program that is not transpiled (Treflove, whose chunks LÖVE loads
itself) can use the runtime through ordinary calls with the semantics of
the syntax: `lifetime.attach(obj, a1, …, an)` for `obj @ (a1, …, an)`
(the emitter's `pin` flag is gone from the public signature),
`lifetime.hook(f, a1, …, an)` for `f !@ (a1, …, an)`,
`lifetime.named_hook(name, f, a1, …, an)` for a hook bound to a name, and
`lifetime.block(fn, …)`, which runs `fn(scope, …)` in a block of its own
and hands it the record to anchor to. Requested by the human for the
lua-lifetime branch of Treflove, which writes `lifetime.attach(obj,
self)` where a `.lt` file would write `@ self`.

## Spec

- `docs/02-semantics.md`, "The library form": the four entry points, the
  table of syntax against library form, the record as a value valid
  inside `fn` only, `attempt to anchor to a dead scope`, the results
  passed through, the position of `fn` as `<where>`.
- `docs/02-semantics.md`, "Acquiring a lifetime: the `@` operator" (steps
  1 to 4, which `attach` performs) and "Hooks: the `!@` operator",
  "Named hooks" (what `hook` and `named_hook` make).
- `docs/02-semantics.md`, "Scopes: `lifetime.scope`": "There is therefore
  no dead scope token" holds for the syntax; the library form's record
  is dead after `fn` returns and says so.
- `docs/03-runtime.md`, "Attachment: what `@` does", "Hooks", "Scope
  records" (the library form's record), "Performance" (the row for
  `lifetime.block`).
- `docs/04-transpiler.md`, "What `@` expands to": the new expansions,
  `__lt_named_hook` in the header.
- `docs/05-decisions.md`, "The runtime is usable as a library".
- `docs/05-decisions.md`, "A LÖVE host announces program end from
  `love.quit`": settles the open question "How an embedding host
  announces program end" (docs only: `lifetime.set_exiting` as it already
  existed; `docs/02` "Program end" step 2 and `docs/03` "Program end"
  amended), carried by this branch for the Treflove side, which calls it
  from its `love.quit` callback.

## Acceptance criteria

- `lifetime.attach(obj, a1, …, an)` returns `obj` and anchors it as `@`
  does; `lifetime.attach(obj)` is `bad argument #2 to 'lifetime.attach'
  (anchor expected, got no value)`, raised at the caller.
- `lifetime.hook(f, a1, …)` and `lifetime.named_hook(name, f, a1, …)`
  make the hooks `!@` makes; the anchor errors are numbered `#2` and
  `#3`; a non-string name is `bad argument #1 to 'lifetime.named_hook'`.
- `lifetime.block(fn, …)` returns every result of `fn`, trailing `nil`s
  included; its dependents die at the return, newest first, reason
  `"anchor"`; a destructor error is raised at the call after the
  cascade; an error in `fn` unwinds the record at the raise point; `fn`
  may yield; the record is dead afterwards and anchoring to it raises
  `attempt to anchor to a dead scope`; `lifetime.block(5)` is `bad
  argument #1 to 'lifetime.block' (function expected, got number)`.
- The tombstone of a dependent of a library-form block names the chunk
  and the line of `fn`.
- The emitter writes `__lt_attach(e, a)`, `__lt_hook(f, a)` and
  `__lt_named_hook("h", f, a)`; the Teal front end the same; every
  example's output is unchanged.
- `make test` green under `lua5.1` and `luajit`; `make lint` clean.

## Test cases

`tests/test-library.lua`, suites "library: attach and hook" and
"library: block": the attach and hook signatures and errors; a block
whose dependents `x`, `y` and a hook `h` die as `h (anchor)`, `y
(anchor)`, `x (anchor)` after `body done`; nested blocks (`inner body`,
`hb (anchor)`, `b (anchor)`, `after inner`, `a (anchor)`); an
unreferenced dependent collected before the exit, pinned with two
`collectgarbage("collect")`; an error in `fn` (`h (anchor)`, `x (anchor)`
before `pcall` returns); a destructor error raised at the call after the
whole cascade; a yield across the block; the dead record; a block inside
a destructor body. The sentence most likely to be misread: "The record
is a value here, which the syntax never gives: it is valid inside `fn`
only"; the dead-record case covers it, for a record that had dependents
and for one that had none (`lifetime.exit` now marks an empty record
dead too), and asserts that `of`, `destroy` and `discard` refuse the
record inside the function and once it is dead alike (`got scope`), and
that a `lifetime.pin` value made from it names the dead record a scope.

## Performance

`bench/bench-scopes.lua`: `scope/block-one-object`, `scope/block-closure`
and `scope/block-empty` (`bench/README.md`). What stays free: generated
code is unchanged but for one argument less per `attach` and `hook`
call; `attach`'s fast path lost the `pin` test; `lifetime.exit` of an
empty record gained one store. `lifetime.block` reads `debug.getinfo`
only in a cascade that has something to destroy, never per entry. On
2026-10-18 (`make bench BENCH_FILES=bench/bench-scopes.lua
INTERPRETERS=luajit`, one invocation, LuaJIT 2.1, ns per 10 operations):
`scope/block-one-object` 9 300 against `scope/loop-one-object` 4 250
(the generated form of the same block: the closure call and the vararg
frame for the results cost about as much as the record and the
attach), `scope/block-closure` 11 400 (the closure made per entry),
`scope/block-empty` 840 against `scope/enter-exit-empty` 790. The
baselines fold under the trace compiler, so the printed ratios of the
`block-*` rows say little beyond "a closure call the compiler cannot
sink"; the absolute numbers are the comparison. `scope/loop-one-object`
and `scope/hook-on-scope` are within their previous range.

`make bench BASE=master` cannot run the branch's `runtime/*`,
`scope/loop-one-object`, `scope/hook-on-scope` and `sentinel/*` rows on
the base: `attach` lost an argument, so master's runtime raises `bad
argument #3 to 'lifetime.attach'` on the branch's files, and the compare
prints `-` for them. Those rows were compared by alternating the branch's
benchmark files on the branch against master's own files in `build/base`,
two pairings per interpreter (the reviewer's method, round 1): every row
within the noise band of `bench/README.md`; `runtime/attach-destroy-100`
under LuaJIT 1.21/1.11 in one pairing, 0.93/0.98 in the next two,
`runtime/attach-first` 0.88/1.08. `sentinel/anchor-100` (round 1, finding
F1) attaches its pinned baseline through a `lifetime.pin(anchor)` value
now, which takes `attach`'s general path, so its ratio reads the
sentinel's cost over the general path's. On 2026-10-19 (`make bench
BASE=master`, the two pairings of one invocation, ns per operation):
333 467 / 327 800 under Lua 5.1 at 0.73 / 0.74 of that baseline, which
says the general path costs more than the sentinel there, and 57 779 /
55 686 under LuaJIT at 1.04 / 1.03; the base cannot run the row (`-`). The
`scope/block-*` rows follow `scope/resume-yield` now, so a base without
`lifetime.block` fails after the rows it can run (finding F4:
`scope/pcall-empty` under LuaJIT had been marked in two invocations as an
artifact of the base process raising early). After the reorder, the
same invocation reads `scope/pcall-empty` 0.924 / 0.956 under Lua 5.1
and 1.340 / 0.852 under LuaJIT (median 1.095), not marked, and the whole
`make bench BASE=master` exits 0 with no `SLOWER` mark under either
interpreter. Round 2 saw the row marked again under LuaJIT (1.239 /
1.216, then 1.127 / 1.279), since `scope/loop-one-object` and
`scope/hook-on-scope` still raised on the base ahead of it; those two
rows follow `scope/resume-yield` now as well, so every row a base
without this task's `attach` can run comes first. A full `make bench
BASE=master` on that tree (2026-10-19) exits 0 and reads
`scope/pcall-empty` 1.028 / 1.083 under Lua 5.1 and 0.985 / 0.704 under
LuaJIT, not marked; its two marks elsewhere, `scope/enter-exit-empty`
under Lua 5.1 (1.141 / 1.102) and `treflove/cycle` under LuaJIT (1.131 /
1.174), read 1.009 / 0.998 and 1.041 / 1.142 on the next invocation of
those files (`BENCH_FILES="bench/bench-scopes.lua
bench/bench-treflove.lua"`), so neither is a finding by the threshold
rule of `bench/README.md`.

## Out of scope

- Any change to the syntax or the transpiled semantics: `lifetime.scope`
  stays syntax, the marker stays, the generated code's shape is the same.
- A LuaJIT-only or 5.4 path.

## Spec issues found

1. `docs/05-decisions.md`, "The scope anchor is spelled `lifetime.scope`",
   says "A scope remains unstorable: 'there is no scope value' holds".
   The library form hands the record to a function as a value. Settled by
   the human's request as a decision of this repository ("The runtime is
   usable as a library"): the sentence still holds for the language, and
   the library form's record is specified as valid inside `fn` only, dead
   afterwards, with its own error text.
2. An empty scope record was never marked dead at `lifetime.exit`, since
   generated code cannot reach it afterwards; the library form can. Fixed
   as part of this task (one store on that path).
3. The open question "How an embedding host announces program end" (task
   009 left it for Treflove) is settled on this branch by the Treflove
   side's `love.quit` callback: `docs/05-decisions.md`, "A LÖVE host
   announces program end from `love.quit`", with `docs/02` "Program end"
   step 2 and `docs/03` "Program end" amended; no code changed. Cited in
   the Spec list on the reviewer's finding F3.

## Review log

Implemented by the human's session directly (the Treflove comparison
branch needed it in one sitting), then reviewed by the reviewer agent.

Round 1 (2026-10-19): REQUEST_CHANGES. F1 (blocking):
`bench/bench-sentinel.lua` still passed the removed `pin` flag, so `make
bench` failed on the branch; fixed, the pinned baseline goes through a
`lifetime.pin(anchor)` value (README row and Performance updated). F2:
a stale `pin: boolean` in docs/04's Teal declaration sentence; fixed.
F3: the `love.quit` decision the branch carries was not cited; now in
the Spec list and "Spec issues found" 3. F4: `scope/pcall-empty` marked
`SLOWER` under LuaJIT in two invocations as an artifact of the base
process raising on the `block-*` rows; those rows moved after
`scope/resume-yield`. F5: how the signature-changed rows were compared
is in Performance now. F6: this file's metadata (`branch`, `status`,
this log). Questions: docs/03 names the dying record too; docs/02 "The
library form" says what the other entry points do with the record.

Round 2 (2026-10-19): REQUEST_CHANGES. Every round-1 finding
resolved. F1 (blocking): the sentence added in round 1 for the other
entry points held inside `fn` only: `lifetime.of` on the dead record
reached the dead-object branch first and formatted a tombstone message
through `name_of`, which took the record's `fn` field for a hook's;
`destroy` and `discard` on it were silent no-ops. Fixed: `of` and
`destroy_target` test for the marker or a record before they test for
death, so the dead record is refused as the live one is; the record's
function is kept under `body`; docs/02 and docs/03 say so; the
dead-record test covers the three entry points inside the function and
after it. F2: a dead record reached through a `lifetime.pin` value was
named `dead table`; `check_anchor`'s value branch names a scope now,
tested. F3: the dead-record test covers a record that had dependents
too, as the Test cases section said. F4: `scope/pcall-empty` marked
again under LuaJIT, with the base still raising on two earlier rows of
the file; `scope/loop-one-object` and `scope/hook-on-scope` moved after
`scope/resume-yield` as well, the result recorded in Performance.

Round 3 (2026-10-19): APPROVE, no finding. Every round-2 finding
verified resolved; `make test` 423/423 under lua5.1 and luajit,
conformance 77/77, the trial, luals-check; `make lint` clean; `make
bench BASE=master` with no `SLOWER` mark under either interpreter
(`scope/enter-exit-empty` 0.855 / 1.071 and 1.011 / 1.004,
`scope/pcall-empty` 0.996 / 0.962 and 0.980 / 0.992), the rows the base
cannot run within 0.90 to 1.10 of master's own files on master's
runtime. Traced: a record that had nothing attached; a destructor and a
hook anchoring to the record during the exit (`dying scope`, raised at
the block call after the cascade); a library block inside a generated
block unwound innermost first with the tombstones' positions; a callee
of `fn` anchoring to the record; a block in a coroutine that yields and
raises; the marker; the caller positions of the no-anchor errors.
Follow-ups noted, not required: a test of the caller position of those
errors; a test of `lifetime.dependents(scope)` inside `fn`.
