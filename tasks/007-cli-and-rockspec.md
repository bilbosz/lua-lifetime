---
id: 007
title: CLI `lifetime build` and `lifetime run`; the rockspec installs and runs
status: in-progress
depends: [006]
branch: task/007-cli-and-rockspec
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

- `tasks/001-skeleton-and-conformance-runner.md`, review round 2: a `#!`
  first line is stripped before `build`, as `luaL_loadfile` does (the
  conformance runner and `lifetime run` read the file themselves); and
  `cli.build` classifies a syntax error by a marker rather than by the
  chunkname prefix of the message, since this task chooses chunknames.

- `tasks/006-emitter.md`, review round 1, F1: the comment on the
  emitter's restart optimisation (plain Lua emitted in one pass, restart
  with the block analysis at the first `lifetime.scope`) names
  `build/plain.lt`, `build/generated-5000` and `build/lifetime-largest`;
  this task adds `build/extension-5000` (or similar), `cli.build` on a
  file that uses the extension, so the double emission is measured; and
  gives `emit/return-fixed` and `emit/return-call` a LuaJIT baseline that
  does the same observable work (the hand-written destructor call is
  folded away today), or drops their ratio column.

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
- `run` calls the chunk through the runtime's `pcall`, so an uncaught
  error unwinds every scope left open, the main scope last, and then
  prints `lifetime: <message>` and a traceback on stderr and exits 1.
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

1. **The exit flag after an uncaught error.** 03, "Program end", sets the
   flag "after the main chunk has returned and its scope epilogue has
   run"; 04 says "set after the chunk returns". Neither says what the
   finalizers of the closing state report when the chunk ended with an
   uncaught error, although the state closes then too (the standalone
   interpreter reports, then closes it). Implemented: `run` sets the flag
   after the report as well, so they report `"exit"` (checked against
   task 004's runtime: `destroy local (anchor)`, the report, then
   `destroy global (exit)`). The other reading, `"unreachable"` after an
   error, is one line in `lifetime/cli.lua`. 03 could say which.
2. **The exit flag's name.** Nothing in `docs/` names it; task 004
   implements `lifetime.set_exiting(flag)` (its spec issue 2) and `run`
   calls it when it exists. Until task 004 merges, the test of test case
   1 checks the main-scope half of `tests/fixtures/exit_order.lt` and
   prints a note; the fixture moves to `examples/exit_order.lt` once both
   tasks are on `master` (every example must pass, so it cannot wait in
   `examples/`). Run by hand against task 004's `lifetime/init.lua`
   (`origin/task/004-...` at `6199bf1`), `tests/test-cli.lua` and
   the conformance suite pass under both interpreters, test case 1
   included.
3. **A plain chunk under `lifetime run` pays the runtime's `pcall`.**
   04 says `run` calls the chunk through the runtime's `pcall`, so `run`
   requires the runtime whatever the chunk is, and the runtime replaces
   `pcall`, `xpcall`, `coroutine.resume` and `coroutine.wrap`. A plain
   chunk run as `lua FILE` keeps the originals; under `lifetime run` each
   of its `pcall`s costs the wrapper (`scope/pcall-empty`, ten empty
   `pcall`s: ratio 2.55 under Lua 5.1, about 75 ns more per `pcall`, and
   1.65 under LuaJIT, about 1 ns more; `scope/pcall-error` 1.82 and 1.02). Requiring the runtime only for a
   chunk with a header would miss scopes left open by transpiled modules
   that a plain main chunk requires; unwinding those after the fact needs
   a runtime entry point that does not exist (an unwind to depth 0). The
   task's *Performance* line ("must not add per-call or per-block cost
   over loading the generated file directly") holds for a chunk that uses
   the extension, which requires the runtime itself; for a plain chunk it
   holds except for this. Kept on the spec's side; the human decides.
4. **How the uncaught error is reported, where the standalone
   interpreters differ or the spec is silent.** Choices, each one line in
   `lifetime/cli.lua`: the chunk name is `@FILE`, as `luaL_loadfile`
   gives it (positions read `FILE:LINE:`, a name over 60 bytes keeps its
   tail); a syntax error under `run` reads `lifetime: FILE:LINE:
   <message>` with no traceback, as `lua` reports a load error behind its
   name (`build` keeps the bare shape of 04); a non-string error object
   is rendered as LuaJIT's interpreter renders it (`__tostring`, else
   `(error object is a <type> value)`, `nil` included, where both
   interpreters print nothing for `nil`); the traceback is the raise
   point's, cut below the main chunk (the frames of `lifetime/cli.lua`,
   the runtime's `xpcall` and `bin/lifetime`), so it ends at `FILE:LINE:
   in main chunk` without the interpreter's last `[C]: ?`.
5. **`luarocks` is not installed on this machine**, so the criterion
   "`luarocks make lua-lifetime-dev-1.rockspec` succeeds on both
   configurations" is untested. Tested instead: the rockspec's fields
   and its module list against `lifetime/*.lua` (read as luarocks reads
   the file), and the command run from outside the checkout in the
   layout a builtin rock installs (modules under the tree's
   `share/lua/5.1`, `lifetime` as `lifetime/init.lua`, the script under
   the rock's `bin/`, the tree put on `package.path` by `-e` as the
   luarocks wrapper does), under both interpreters.

## Review log

### Round 1: REQUEST_CHANGES

Suite on `b5edd6f`: unit 250/250 under lua5.1 and luajit, conformance 19/19 under both (with the `note:` line until task 004 merges), lint clean (28 files). `make bench BASE=master`: nothing marked; the new rows `build/extension-5000`, `build/scope-at-end-5000`, `run/plain.lt` present; `emit/return-*` LuaJIT ratios now 7.2 to 7.4 and 18.7 to 19.0; the restart comment names all five build benchmarks and the measured 1.4x. In a mixed tree with task 004's `lifetime/init.lua`: 250/250, 19/19, the full exit order under both interpreters, and after an uncaught error a registered global dies with `exit` after the report. Traced by hand: `uncaught_error.lt` (handler at the raise point, `inner`, `second`, `first` unwound, stdout flushed, the report, the traceback trimmed at the main chunk, `error(nil)` closing the state with exit 1); an error through `coroutine.wrap` (the coroutine's scope unwound in the resumer, then the main scope, then the report); a 40-deep recursion, a stack overflow, `error(nil)`, `error(42)`, `arg[-3]` and `arg[-1]`.

- F1 (blocking): a syntax error with a non-ASCII `goto` label (`goto lä` into a scoped block; the lexer accepts bytes 128 to 255 in names) does not match `GOTO_ERROR` in `lifetime/cli.lua` (`[%a_][%w_]*` stops at the first high byte), so `cli.build` re-raises it as a transpiler bug and the interpreter reports it with a traceback instead of `FILE:LINE: <message>`. Fix: the name class of the lexer, `<goto [%a_\128-\255][%w_\128-\255]*>`, plus one in-process case in the marker test expecting `{nil, "x:1: <goto lä> jumps into the scope of a lifetime"}`.
- Rulings 1 to 6 hold on the code as written. Ruling 3 (a chunk under `lifetime run` has the runtime loaded and pays its `pcall` wrapper) goes into `docs/04`, "The command", in the done chore.
- Runtime notes for a follow-up, not this task: the default `destroyerror` handler writes to stderr without flushing stdout first; an error through `coroutine.wrap` shows the runtime's wrapper frames above the main chunk where the standalone interpreter shows `[C]: in function 'w'`.
- After task 004 merges: move `tests/fixtures/exit_order.lt(.expected)` to `examples/` and drop the `set_exiting` conditional and the `note:` line.
