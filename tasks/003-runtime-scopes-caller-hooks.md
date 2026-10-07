---
id: 003
title: Runtime: scope records, `caller` depth counter, hooks
status: todo
depends: [002]
branch:
pr:
commits:
review:
---

## Goal

The runtime provides what the emitter's block and function code will
call: `lifetime.enter()` / `lifetime.exit(record, line, ok, err)` for
scope records, the per-coroutine depth tables (`lifetime.S`,
`lifetime.drop`, `lifetime.caller()`) that the inline `caller` prologue
and epilogue use, and `lifetime.hook(f, a1, …)` for hooks. Tests drive
them by hand, writing the inline prologue and epilogue of
`docs/04-transpiler.md` as generated code would.

## Spec

- `docs/02-semantics.md`, "Scopes: `scope` and `caller`": a scope's
  dependents die at block exit "by any route"; each entry is a new scope;
  `caller` is "the innermost block of the calling function"; functions the
  transpiler did not generate are transparent.
- `docs/02-semantics.md`, "Hooks: the `!` operator": default lifetime is the
  block's scope; a hook is pinned; "A hook on an object runs **after**
  that object's `__destroy`, interleaved with the object's other
  dependents by attachment order, most recently attached first"; called
  as `fn(reason)`; metatable `"hook"`; `discard` cancels, `destroy` runs,
  `@` re-targets; errors follow the destructor rule. "Named hooks": a
  named hook's `tostring` is `hook NAME`; after it runs it is dead,
  `lifetime.alive` is `false`, `destroy` and `discard` are no-ops.
- `docs/02-semantics.md`, "Cascading death": "A scope has no body: scope
  exit destroys the objects anchored to it in reverse attachment order".
- `docs/02-semantics.md`, "Errors in destructors": an error already
  propagating (the `ok == false` path of `exit`) routes later errors to
  `destroyerror` and the original continues.
- `docs/03-runtime.md`, "Scope records and `caller`": one table `D` per
  coroutine with the depth in `D.n` and records in `D[d]`; `S.D` swapped
  on coroutine switches by the wrapped `coroutine.resume`, `wrap` and
  `yield`; the epilogue assigns the depth; a record at depth `d - 1`
  allocated on first use.
- `docs/03-runtime.md`, "Performance": the inline prologue makes no call
  and allocates nothing unless a callee asked for `caller`.
- `docs/06-open-questions.md`, "`caller`: function granularity and the
  error path": the task implements function granularity and the normal
  path only; the error path of the counter stays open and is not solved
  here.

## Acceptance criteria

- `lifetime.enter()` returns a scope record with metatable `"scope"`;
  `lifetime.exit(record, line)` runs the cascade with the record as root
  and no body, dependents in reverse attachment order with reason
  `"anchor"`, and `<where>` for their tombstones is `chunk:line`.
- `lifetime.exit(record, line, false, err)` runs the cascade with the
  error counted as propagating (every destructor error goes to
  `destroyerror`) and then re-raises `err` unchanged.
- `lifetime.S.D` is the depth table of the running coroutine, with
  `D.n == 0` in a fresh coroutine and in the main thread before any
  generated function ran. The inline prologue (`local __D = S.D; local __d
  = __D.n + 1; __D.n = __d`) and epilogue (`if __D[__d] then
  lifetime.drop(__D, __d) end; __D.n = __d - 1`) are the whole protocol.
- `lifetime.drop(D, d)` destroys the record `D[d]` (its dependents in
  reverse order, reason `"anchor"`) and clears the slot.
- `lifetime.caller()` returns `D[D.n - 1]`, creating it if absent; at
  depth 1 or 0 it returns the main record, which the runtime creates on
  first use and which `lifetime.exit_main()` (called by `lifetime run`,
  task 007) destroys.
- Requiring the runtime wraps `coroutine.resume`, `coroutine.wrap` and
  `coroutine.yield` so that `S.D` is always the running coroutine's table;
  the wrapped functions keep Lua's return values and errors exactly.
- `lifetime.hook(f, name, a1, …, an)` creates a hook: a table with
  metatable `"hook"`, attached pinned to the anchors (a scope record
  included) through their `hooks` lists, whose body calls `f(reason)`;
  `lifetime.hook(5)` raises `attempt to defer a number value`; calling or
  indexing a hook raises the hook errors.
- With a name, `tostring(h)` is `hook NAME` and `lifetime.format(h)` is
  `hook NAME`; with `nil`, `tostring(h)` is `hook: 0x…`.
- `destroy(h)` on a live hook runs `f("destroy")` once; afterwards
  `lifetime.alive(h)` is `false` and a second `destroy(h)` or `discard(h)`
  does nothing.
- A hook attached to an object runs after the object's `__destroy` and in
  its position among the dependents by attachment sequence.
- `discard(h)` never runs `f`; `destroy(h)` runs it now with `"destroy"`;
  `attach(h, false, other)` moves it.
- `make test` green under both interpreters; `make lint` clean.

## Test cases

1. Scope order: `enter`; `f @ s`; hook "after f"; `g @ s`; hook "runs
   first"; `exit`: log `runs first, g, after f, f` (the example in the spec).
2. Hook after body: `conn` with a logging `__destroy`; hook on `conn`
   logging "hook sees " .. conn.id; `destroy(conn)`: log `conn, hook sees
   conn` and the hook ran while `conn` was still indexable.
3. `caller`: `outer` (with the inline prologue) calling `inner` (with the
   inline prologue); `inner` attaches `x` to `lifetime.caller()`;
   `inner`'s epilogue does not destroy `x`; `outer`'s epilogue does, with
   reason `"anchor"`.
4. Transparent frames: `outer` → plain Lua function (no prologue) →
   `inner`; `caller` in `inner` is `outer`'s record.
4a. Self-healing depth: `inner` raises after its prologue, `outer`
   catches with `pcall`; after `outer`'s epilogue `D.n` is back to the
   value before `outer` was called.
5. Error path of `exit`: a dependent whose body raises `"d"`; `exit(s,
   line, false, "boom")` sends `"d"` to `destroyerror` and raises `"boom"`.
6. Cancel and re-target: `discard` then `exit` logs nothing for the hook;
   a hook moved to `registry` runs at `destroy(registry)` with `"anchor"`.
7. Per-coroutine counters: two coroutines each at depth 2 see their own
   `caller`.

The sentence most likely to be misread: "A hook on an object runs after
that object's `__destroy`", given that for a *scope* hooks are still
last-deferred-first-run. Cases 1 and 2 together pin both readings.

## Performance

Hot paths: the inline `caller` prologue and epilogue (per generated
call), `enter`/`exit` of a scope record (per block entry), hook creation.
Benchmarks: a call-heavy loop with the inline prologue against the same
loop without it; a loop body with one scoped object against hand-written
cleanup. Must stay free: the prologue makes no call and allocates nothing
when no callee asks for `caller` (assert with `collectgarbage("count")`
around a loop of calls).

## Out of scope

- The error path of the depth counter (open question).
- `caller` across coroutine boundaries beyond per-coroutine counters (open
  question).
- Generated code: task 006. Tokens, `pin`, sentinels: task 004.

## Spec issues found

## Review log
