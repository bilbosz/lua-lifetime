---
id: 006
title: Emitter: `@` and lists, hooks (`!@`), block epilogues on every exit path, the `pcall` error path
status: todo
depends: [003, 005]
branch:
pr:
commits:
review:
---

## Goal

The emitter turns the extended AST into Lua 5.1 that calls the runtime:
the chunk header, the `@` expansions, hooks (`!@`, named and anonymous), scope records with
an epilogue on every exit path, and the `pcall` wrapper for blocks that
need it. After this task a
`.lt` program runs through `cli.build` plus `loadstring`, and the
conformance runner can run programs that use the syntax.

## Spec

- `docs/04-transpiler.md`, "The generated chunk header"; "What `@`
  expands to" (the table); "Blocks: prologue and epilogue on every exit
  path" (which blocks need a record; `return`, `break`, `goto`, loop
  bodies, function bodies); "The error path: the `pcall` wrapper" (the
  closure rewrite, `...`, `exit` with `ok, err`); "Functions" (a function
  body is a block, no per-function prologue); "The emitter keeps every
  statement on its source line".
- `docs/02-semantics.md`, "Scopes: `lifetime.scope`": a loop body is a fresh scope
  per iteration; a function body is a scope; there is no `caller`.
- `docs/02-semantics.md`, "Hooks: the `!@` operator": the anchor is always
  written, `f !@ lifetime.scope` being block exit; "Named hooks": the name passed
  for a binding target.
- `docs/02-semantics.md`, "Cascading death": scope dependents in reverse
  attachment order (the runtime does it; the emitter must call `exit` at
  the right moment).
- `docs/03-runtime.md`, "Scope records" (the calls).

## Acceptance criteria

- Every output chunk that uses the extension or names a lifetime builtin
  starts with the header line; any other chunk is emitted unchanged.
- Each row of the expansion table is produced for its source form, with
  `lifetime.scope` resolving to the innermost enclosing block's record
  local.
- A block that contains (directly) `lifetime.scope` as an anchor of `@` or `!@`
  gets `enter` at its start and `exit` on fall-through, before
  every `return` that leaves it (values evaluated first, packed with
  `select("#", …)`), before every `break` that leaves it, and before every
  `goto` that leaves it; a `goto` into such a block is a compile error.
- Such a block is wrapped in the `pcall` closure; `return` and `break`
  inside the closure are re-executed outside; `...` is forwarded; `exit`
  receives `ok, err` and re-raises an error unchanged.
- A block without those constructs is emitted verbatim: no record, no
  wrapper, no closure.
- No function gets a prologue or an epilogue of its own: a function whose
  body does not anchor to `lifetime.scope` is emitted verbatim, call for call.
- The chunk header binds every runtime function the chunk calls to a
  local and names nothing it does not use; a chunk with no extension
  syntax and no lifetime builtin gets no header.
- Output lines match input lines for every statement (a diagnostic test
  that `error()` on line N reports line N through the generated code).
- `make test` green under both interpreters; `make lint` clean. The
  conformance runner passes `examples/plain.lt` and the new examples below.

## Test cases

Each as an `examples/NAME.lt` with its `.expected`, since from here on the
conformance suite is the natural harness; unit tests check the generated
text for the chunk header and for a block that needs no wrapper.

1. `examples/scope_exit.lt`: a `do` block with `a @ lifetime.scope`, `f !@ lifetime.scope`,
   `b @ lifetime.scope`; expected `b, hook, a`-style log on fall-through.
1a. `examples/named_hook.lt`: `local hook = function(r) print("ran " ..
   r) end !@ owner`; `print(tostring(hook))` prints `hook hook`;
   `destroy(hook)` prints `ran destroy`; a second `destroy(hook)` prints
   nothing; `print(lifetime.alive(hook))` prints `false`; `destroy(owner)`
   afterwards prints nothing for the hook. A second hook is cancelled
   with `discard` and a third moved with `@` to another owner.
2. `examples/block_exits.lt`: the same block left by `return`, by
   `break` inside a loop, and (under LuaJIT only; skipped on 5.1 by
   checking `jit`) by `goto`; each prints the log in order and the return
   value arrives intact, including a trailing `nil` in `return 1, nil`.
3. `examples/unwind.lt`: an error raised inside a block with scope
   dependents, caught by `pcall` outside; the dependents' log lines appear
   before `pcall` returns `false`, with the original message and position.
4. `examples/receiver_anchors.lt`: `open_log()` returns its result on the
   default lifetime; the receiver writes `local log = open_log() @ lifetime.scope`
   and its block exit destroys it; a second receiver that does not anchor
   keeps the object until `collectgarbage("collect")`.
5. `examples/loop_scope.lt`: `for i = 1, 3 do local t = {} @ lifetime.scope end`
   logs three deaths, one per iteration, each before the next iteration's
   first statement.
6. `examples/plain.lt` is unchanged and still passes.

The sentence most likely to be misread: "A block that needs a scope
record if it contains, **directly** (not in a nested function) …". A
`f !@ lifetime.scope` inside a nested function body belongs to that function's
body block, not to the enclosing block. Case 1 adds a nested function with
its own `f !@ lifetime.scope` to pin it.

## Performance

Hot paths: everything the emitter writes. Benchmarks: a scoped block in a
loop (record, wrapper and epilogue) against hand-written cleanup; the
same loop with no scoped object (must equal plain Lua); a call-heavy
function (must equal plain Lua: no prologue exists); `return` through a
block epilogue. Must stay free: a block with no `@ lifetime.scope` and no
`!@ lifetime.scope` is emitted verbatim; a function that does not anchor to
`lifetime.scope` is emitted verbatim; a chunk with no extension syntax gets no
header. The numbers for the
wrapper are the evidence for "Catch-site unwinding" in
`docs/06-open-questions.md`; report them.

## Out of scope

- The command and `lifetime run`: task 007 (tests load generated code with
  `loadstring`).
- The open "Catch-site unwinding" alternative; this task implements the
  per-block wrapper as specified.

## Spec issues found

## Review log
