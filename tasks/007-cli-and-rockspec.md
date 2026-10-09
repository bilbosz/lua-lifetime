---
id: 007
title: CLI `lifetime build` and `lifetime run`; the rockspec installs and runs
status: todo
depends: [006]
branch:
pr:
commits:
review:
---

## Goal

`bin/lifetime build FILE -o OUT` and `bin/lifetime run FILE [ARGS]` work
from a checkout under both interpreters, and `luarocks make
lua-lifetime-dev-1.rockspec` installs the module and the command so that
`lifetime run` works from anywhere. `run` sets the exit flag so the final
sweep reports `"exit"`, and the main scope is destroyed when the chunk
returns.

## Spec

- `docs/04-transpiler.md`, "The command": the two subcommands, `-o -`,
  the syntax-error shape, the chunk name, `arg`, the exit flag, the
  uncaught-error report `lifetime: <message>` with exit status 1.
- `docs/02-semantics.md`, "Program end": the main scope exits first, reason
  `"anchor"`; then finalizers at state close report `"exit"` under `run`.
- `docs/03-runtime.md`, "Program end".
- `docs/01-overview.md`, "Rocks": summary *Ownership and destructors for
  Lua.*; no `teal-lifetime` rockspec yet.
- `examples/README.md`: the runner may switch from `tests/lib/driver.lua` to
  `lifetime run` once it exists, keeping the chunk name and the exit
  status contract.

## Acceptance criteria

- `lifetime build FILE -o OUT` writes the transpiled source; `-o -`
  writes to stdout; a missing `-o` is a usage error (exit 2, usage on
  stderr); a syntax error prints `FILE:LINE: <message>` and exits 1.
- `lifetime run FILE a b` runs the program with `arg[0] == FILE`, `arg[1]
  == "a"`, and the chunk name `FILE`; the program's `return` value is
  ignored; exit status 0.
- After the chunk returns, its own scope epilogue having destroyed the
  objects anchored to the main chunk's `lifetime.scope` (reason `"anchor"`), `run`
  sets the exit flag; a global with a
  `__destroy` registered through `@` prints at exit with reason `"exit"`.
- An uncaught error prints `lifetime: <message>` and a traceback on stderr
  and exits 1, after the main scope's cascade has run.
- `luarocks make lua-lifetime-dev-1.rockspec` succeeds on both `luarocks
  --lua-version 5.1` configurations the machine has, installs
  `lifetime`, `lifetime.lexer`, `lifetime.parser`, `lifetime.emit`,
  `lifetime.cli` and the `lifetime` script, and `lifetime run
  examples/plain.lt` prints the expected output from a directory outside
  the checkout.
- `tests/conformance.lua` runs each example through `lifetime run` under
  each interpreter (replacing the bootstrap's `tests/lib/driver.lua`) and still
  honours the `!error:` contract with the `lifetime: ` prefix.
- `make test` green under both interpreters; `make lint` clean.

## Test cases

1. `examples/exit_order.lt`: two registered globals with destructors and
   a main-scope local; expected output ends with the main-scope local
   (`anchor`), then the globals newest first (`exit`).
2. `examples/uncaught_error.lt`: a main-scope dependent, then `error("x")`;
   the dependent's line prints, then the `.expected` ends with `!error:
   examples/uncaught_error.lt:N: x`.
3. A unit test runs `bin/lifetime build` on `examples/plain.lt` with `-o
   -` and compares with `cli.build`'s result.
4. A shell-level test (in `tests/test-cli.lua` through `io.popen`) checks
   the usage error's exit status 2 and the syntax error's shape.

The sentence most likely to be misread: "An uncaught error is reported …
after the main scope's cascade has run". The cascade must run before the
message is printed, not after. Case 2's output order pins it.

## Performance

Hot path: none new; `lifetime run` must not add per-call or per-block
cost over loading the generated file directly. Benchmark: startup time of
`lifetime run examples/plain.lt` against `lua5.1`/`luajit` running the
generated file.

## Out of scope

- The `teal-lifetime` rockspec.
- Embedding-host program end (open question).
- Any change to the generated code's shape.

## Spec issues found

## Review log
