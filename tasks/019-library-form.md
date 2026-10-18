---
id: 019
title: The runtime as a library: `lifetime.attach(obj, a1, …)`, `lifetime.hook(f, a1, …)`, `lifetime.named_hook` and `lifetime.block` for programs that are not transpiled
status: done
depends: [018]
branch: ccr-e2ff185c-4fk5oo
pr:
commits:
review:
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
dead too).

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

## Review log

Done by the human's session directly, outside the implement/review loop
(the Treflove comparison branch needed it in one sitting). Self-checked:
`make test` under `lua5.1` and `luajit`, `make lint`, `make
luals-check`, the Treflove trial, and `make bench
BENCH_FILES=bench/bench-scopes.lua`.
