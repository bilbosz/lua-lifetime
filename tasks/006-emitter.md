---
id: 006
title: Emitter: `@` and lists, hooks (`!@`), block epilogues on every exit path
status: in-progress
depends: [003, 005]
branch: task/006-emitter
pr:
commits:
review:
---

## Goal

The emitter turns the extended AST into Lua 5.1 that calls the runtime:
the chunk header, the `@` expansions, hooks (`!@`, named and anonymous), scope records with
an epilogue on every ordinary exit path (the error path is the
runtime's). After this task a
`.lt` program runs through `cli.build` plus `loadstring`, and the
conformance runner can run programs that use the syntax.

## Spec

- `docs/04-transpiler.md`, "The generated chunk header"; "What `@`
  expands to" (the table); "Blocks: prologue and epilogue on every exit
  path" (which blocks need a record; `return`, `break`, `goto`, loop
  bodies, function bodies; the lines passed to `enter` and `exit`); "The
  error path: unwinding at the catch site" (the emitter emits nothing for
  it); "Functions" (a function body is a block, no per-function
  prologue); "The emitter keeps every
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
- No block is wrapped: no closure, no `pcall`, no rewrite of `return`,
  `break` or `...`; `enter` receives the line of the block's `end`.
- A block without those constructs is emitted verbatim: no record.
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
text for the chunk header and for a block that needs no record.

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
   before `pcall` returns `false`, with the original message and position;
   the same block run inside a coroutine yields mid-block under both
   interpreters and its dependents die at the block's `end` after the
   resume.
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
loop (record, push, pop and epilogue) against hand-written cleanup, under
`luajit -jv` to show the loop compiles; the
same loop with no scoped object (must equal plain Lua); a call-heavy
function (must equal plain Lua: no prologue exists); `return` through a
block epilogue. Must stay free: a block with no `@ lifetime.scope` and no
`!@ lifetime.scope` is emitted verbatim; a function that does not anchor to
`lifetime.scope` is emitted verbatim; a chunk with no extension syntax gets no
header. Report the numbers; they are the first for the error-path design
of `docs/05-decisions.md`, "Scopes unwind at the catch site".

## Out of scope

- The command and `lifetime run`: task 007 (tests load generated code with
  `loadstring`).

## Spec issues found

Found by the implementer, round 1. None changes what a program observes;
each says what the code does and why, for the reviewer and the human.

1. **`e @ lifetime.pin(a, b)` comes out as `__lt_attach(e, false,
   (lifetime.pin(a, b)))`.** The row of `docs/04-transpiler.md`, "What `@`
   expands to", shows no parentheses, while task 005's note for this task
   (from 02, "Acquiring a lifetime": "Evaluate each element") asks for a
   call or `...` as the last anchor item to be truncated to one value. The
   emitter cannot tell `lifetime.pin` from any other call (`lifetime` is an
   ordinary name), so every call in that position is parenthesised;
   `lifetime.pin` returns one value, so nothing differs at run time. 04's
   table could say "a call or `...` as the last item is parenthesised".
2. **A `goto` to a label at the end of a block with a record.** LuaJIT
   lets a `goto` jump over a local only to a label at the end of its block
   (the `continue` idiom: `goto continue` ... `local y` ... `::continue::
   end`). An epilogue written after that label would make it no longer the
   last statement and LuaJIT would refuse the jump ("jumps into the scope
   of local"). The emitter writes the epilogue before a block's trailing
   labels and runs it before every `goto` to one of them, with the
   position of the block's `end`, which is what jumping to the label and
   falling through to `end` does. 04, "Blocks", says only "the epilogues of
   the blocks the jump leaves"; the reading is that a jump to a trailing
   label leaves the block as falling through does. No such treatment in a
   `repeat` body: LuaJIT never counts a label before `until` as the end.
3. **"Names a lifetime builtin."** Read as: the chunk refers to one of the
   global names `lifetime`, `destroy`, `discard` (an Id not shadowed by a
   local, parameter or loop variable in scope), as an expression or as an
   assignment target. A plain chunk that assigns the global (`lifetime =
   require("lifetime")`) therefore gets the header and assigns its local
   instead of the global. 04 says "A source file that shadows these names
   gets what it wrote" for the opposite case. Question, current choice:
   targets count.
4. **The positions given to `enter`.** "The line of the block's `end`":
   for a block closed by another token the emitter uses that token's line
   (`elseif`, `else` for an `if` branch, `until` for a `repeat` body), and
   for the main chunk the line of `<eof>`; the fall-through epilogue passes
   the same position.
5. **`return` with a call or `...` last packs through a helper in the
   header.** Lua 5.1 has no `table.pack`, the values of a call can only be
   counted inside a vararg function, and the runtime exports no packer, so
   a chunk that needs it defines `local function __lt_pack(...) return {n
   = __lt_select("#", ...), ...} end` once in its header, beside
   `__lt_unpack` and `__lt_select` bound to `unpack` and `select`. The cost
   is one table per such `return` (`emit/return-call`); LuaJIT stitches
   around `unpack`.
6. **A loop that owns an object is not one LuaJIT trace with the current
   runtime.** 04, "The error path", says "A loop whose body owns something
   is still one trace for LuaJIT". Nothing the emitter writes stops the
   trace: with a loop-free stand-in of `attach`, `enter` and `exit`, `luajit
   -jv` records the generated loop as one trace (`[TRACE 4 scoped.lt:3
   loop]`). With the real runtime the root trace aborts with `inner loop in
   root trace at init.lua:691`, the tombstone's `for k in next, obj` that
   clears the dying object's fields (task 002), and the loop runs in the
   interpreter with the cascade's own traces linked in. This is the
   runtime's (task 004 is working in `lifetime/init.lua`), not a change to
   the semantics; recorded for the runtime and for 03, "Performance".
7. **`lifetime.alive` is not on master yet** (task 004). Test case 1a
   prints `lifetime.alive(hook)`; `examples/named_hook.lt` shows the dead
   hook through `tostring` (`dead hook hook`) and `getmetatable`
   (`dead`) instead, both from 02, "Tombstones and `lifetime.alive`". A
   line with `lifetime.alive` can be added once task 004 is merged.

## Review log
