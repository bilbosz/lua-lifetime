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
scope records, `lifetime.enter_call()` / `lifetime.exit_call()` /
`lifetime.caller()` for the depth counter, and `lifetime.hook(f, a1, …)`
for hooks. Tests drive them by hand, as generated code would.

## Spec

- `docs/02-semantics.md`, "Scopes: `scope` and `caller`": a scope's
  dependents die at block exit "by any route"; each entry is a new scope;
  `caller` is "the innermost block of the calling function"; functions the
  transpiler did not generate are transparent.
- `docs/02-semantics.md`, "`defer` and hooks": default lifetime is the
  block's scope; a hook is pinned; "A hook on an object runs **after**
  that object's `__destroy`, interleaved with the object's other
  dependents by attachment order, most recently attached first"; called
  as `fn(reason)`; metatable `"hook"`; `discard` cancels, `destroy` runs,
  `@` re-targets; errors follow the destructor rule.
- `docs/02-semantics.md`, "Cascading death": "A scope has no body: scope
  exit destroys the objects anchored to it in reverse attachment order".
- `docs/02-semantics.md`, "Errors in destructors": an error already
  propagating (the `ok == false` path of `exit`) routes later errors to
  `destroyerror` and the original continues.
- `docs/03-runtime.md`, "Scope records and `caller`": records per
  coroutine; a record at depth `d - 1` allocated on first use.
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
- `lifetime.enter_call()` increments the per-coroutine depth;
  `lifetime.exit_call()` destroys the record at the current depth if one
  exists (its dependents in reverse order, reason `"anchor"`) and
  decrements. `lifetime.caller()` returns the record at `depth - 1`,
  creating it if absent; at depth 1 or 0 it returns the main record, which
  the runtime creates on first use and which `lifetime.exit_main()` (called
  by `lifetime run`, task 007) destroys.
- `lifetime.hook(f, a1, …, an)` creates a hook: a table with metatable
  `"hook"`, attached pinned to the anchors (a scope record included), whose
  body calls `f(reason)`; `lifetime.hook(5)` raises `attempt to defer a
  number value`; calling or indexing a hook raises the hook errors.
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
3. `caller`: simulate `outer` (enter_call) calling `inner` (enter_call);
   `inner` attaches `x` to `lifetime.caller()`; `inner`'s `exit_call` does
   not destroy `x`; `outer`'s `exit_call` does, with reason `"anchor"`.
4. Transparent frames: `outer` → plain Lua function (no enter_call) →
   `inner`; `caller` in `inner` is `outer`'s record.
5. Error path of `exit`: a dependent whose body raises `"d"`; `exit(s,
   line, false, "boom")` sends `"d"` to `destroyerror` and raises `"boom"`.
6. Cancel and re-target: `discard` then `exit` logs nothing for the hook;
   a hook moved to `registry` runs at `destroy(registry)` with `"anchor"`.
7. Per-coroutine counters: two coroutines each at depth 2 see their own
   `caller`.

The sentence most likely to be misread: "A hook on an object runs after
that object's `__destroy`", given that for a *scope* hooks are still
last-deferred-first-run. Cases 1 and 2 together pin both readings.

## Out of scope

- The error path of the depth counter (open question).
- `caller` across coroutine boundaries beyond per-coroutine counters (open
  question).
- Generated code: task 006. Tokens, `pin`, sentinels: task 004.

## Spec issues found

## Review log
