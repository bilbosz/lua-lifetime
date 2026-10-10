---
id: 016
title: Emitter: drop the `destroy`/`discard` builtin binding; `lifetime.destroy` and `lifetime.discard` are the only spelling
status: todo
depends: []
branch:
pr:
commits:
review:
---

## Goal

The transpiler no longer binds a chunk's free names `destroy` and
`discard` to the runtime: the generated header binds `lifetime` and the
runtime entry points only, `destroy` and `discard` are ordinary names,
and every test, benchmark source and document that showed the old
header or called the bare builtins uses `lifetime.destroy` and
`lifetime.discard`.

## Spec

- `docs/05-decisions.md`, "`destroy` and `discard` are spelled
  `lifetime.destroy` and `lifetime.discard`": "the header binds only
  `lifetime` and the runtime entry points the generated code calls.
  `destroy` and `discard` are ordinary names: a program that defines its
  own is not shadowed, and a chunk that names neither `lifetime` nor the
  extension syntax is its input unchanged."
- `docs/04-transpiler.md`, "The generated chunk header": the header line
  is `local lifetime = require("lifetime"); local __lt_attach = ...`;
  "There are no builtins"; "An assignment to the global `lifetime` in a
  transpiled chunk assigns the header's local".
- `docs/02-semantics.md`, "Explicit destruction: `destroy` and
  `discard`": `lifetime.destroy(5)` is `bad argument #1 to 'destroy'
  (object expected, got number)` (unchanged: Lua names the field).
- `examples/README.md` and `docs/07-conformance.md`: every example
  already calls `lifetime.destroy`; no `.expected` changes.

## Acceptance criteria

- `lifetime/emit.lua`: the `BUILTIN` table and `st.used.destroy` /
  `st.used.discard` are gone; `header` emits the `lifetime` binding when
  the chunk names `lifetime` or uses the extension syntax, and the
  builtins line never. `destroy(x)` in a source transpiles to
  `destroy(x)` with no header when nothing else names `lifetime`.
- `tests/test-emit.lua`: the header cases expect the new line; a case
  shows `destroy(x)` alone is its input unchanged, a case shows a chunk
  with its own `local function destroy() end` and a `lifetime.destroy`
  call gets the `lifetime` binding only; `tests/test-cli.lua` and
  `tests/test-parser.lua` (if they name the builtins) follow.
- `bench/bench-emit.lua`: its source strings call `lifetime.destroy`;
  `make bench BASE=master` twice, `emit/*` rows within the threshold
  (`bench/README.md`); the header is one binding shorter, so nothing
  can be slower.
- `lifetime/parser.lua` and `lifetime/lexer.lua`: no change expected
  (`destroy` was never a keyword); confirm.
- Every `.expected` file unchanged; `make test` and `make lint` green
  under both interpreters.

## Test cases

1. `build("destroy(x)")` is `"destroy(x)"` (no header).
2. `build("lifetime.destroy(x)")` is `LT .. " lifetime.destroy(x)"` where
   `LT` is `local lifetime = require("lifetime");`.
3. `build("local function destroy(t) return t end\nlifetime.destroy(destroy({}))")`
   gets the `lifetime` binding only and leaves the local alone.
4. `build("local x = {} @ lifetime.scope\nlifetime.discard(x)")`: the
   header binds `lifetime`, `__lt_attach`, `__lt_enter`, `__lt_exit` and
   nothing named `discard`.
5. Running `examples/explicit_destroy.lt` and `examples/hooks.lt`
   through `bin/lifetime run` prints their `.expected` unchanged.

The sentence most likely to be misread: "a chunk that names neither
`lifetime` nor the extension syntax is its input unchanged" now covers a
chunk that calls a global `destroy` of its own; case 1 pins it.

## Performance

`emit/*` benchmarks in `bench/bench-emit.lua`; the header shrinks. No
runtime change.

## Out of scope

- Any runtime change; `lifetime.destroy` and `lifetime.discard` already
  exist.
- The documents and examples: rewritten by the spec change
  (`spec/lifetime-destroy`).

## Spec issues found

## Review log
