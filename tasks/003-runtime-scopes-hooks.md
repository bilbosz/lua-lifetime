---
id: 003
title: Runtime: scope records, hooks
status: todo
depends: [002]
branch:
pr:
commits:
review:
---

## Goal

The runtime provides what the emitter's block code will call:
`lifetime.enter()` / `lifetime.exit(record, line, ok, err)` for scope
records and `lifetime.hook(f, name, a1, …)` for hooks. Tests drive them by
hand, writing the block prologue and epilogue of `docs/04-transpiler.md`
as generated code would. Nothing in this task runs per function call:
there is no `caller` anchor and no depth counter (`docs/05-decisions.md`,
"`caller` is removed").

## Spec

- `docs/02-semantics.md`, "Scopes: `scope`": a scope's dependents die at
  block exit "by any route"; each entry is a new scope; "no bookkeeping
  runs per call".
- `docs/02-semantics.md`, "Hooks: the `!@` operator": default lifetime is the
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
- `docs/03-runtime.md`, "Scope records": a record exists only for a
  block that anchors to it; the runtime keeps no depth counter and does
  not wrap `coroutine.*`.
- `docs/03-runtime.md`, "Performance": `enter`/`exit` is "one record (a
  small table) per entry"; a function call costs what it costs in Lua.

## Acceptance criteria

- `lifetime.enter()` returns a scope record with metatable `"scope"`;
  `lifetime.exit(record, line)` runs the cascade with the record as root
  and no body, dependents in reverse attachment order with reason
  `"anchor"`, and `<where>` for their tombstones is `chunk:line`.
- `lifetime.exit(record, line, false, err)` runs the cascade with the
  error counted as propagating (every destructor error goes to
  `destroyerror`) and then re-raises `err` unchanged.
- The runtime exports no `S`, `drop`, `caller` or `exit_main`, and
  requiring it leaves `coroutine.resume`, `coroutine.wrap` and
  `coroutine.yield` untouched (`rawequal` before and after `require`).
- A scope record is a plain small table: `enter()` in a loop of `n`
  iterations allocates `n` records and nothing else when nothing is
  attached (assert with `collectgarbage("count")`).
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
3. Nested records: `enter` an outer record, `enter` an inner one, attach
   `x` to the outer and `y` to the inner; `exit` the inner: only `y` dies;
   `exit` the outer: `x` dies. Records are independent tables; nothing
   links them.
4. Records in a coroutine: a coroutine body that `enter`s a record,
   attaches `x`, yields, and `exit`s after the resume; `x` dies at the
   `exit`, after the resume, and the main thread's records are untouched.
5. Error path of `exit`: a dependent whose body raises `"d"`; `exit(s,
   line, false, "boom")` sends `"d"` to `destroyerror` and raises `"boom"`.
6. Cancel and re-target: `discard` then `exit` logs nothing for the hook;
   a hook moved to `registry` runs at `destroy(registry)` with `"anchor"`.
7. Suspended coroutine collected: a coroutine that `enter`s a record,
   attaches `x` (with a logging `__destroy`) and yields, then is dropped;
   after `collectgarbage("collect")` twice the log shows `x` dying with
   reason `"unreachable"` (the record's sentinel, task 004 provides it;
   until then this case is skipped and named in the review log).

The sentence most likely to be misread: "A hook on an object runs after
that object's `__destroy`", given that for a *scope* hooks are still
last-deferred-first-run. Cases 1 and 2 together pin both readings.

## Performance

Hot paths: `enter`/`exit` of a scope record (per block entry), hook
creation. Benchmarks: a loop body with one scoped object against
hand-written cleanup; `enter`/`exit` of an empty record in a loop. Must
stay free: a function call, which the runtime never sees; a block with
no record, which never calls the runtime.

## Out of scope

- Generated code: task 006. Tokens, `pin`, sentinels: task 004.
- The `pcall` wrapper and "Catch-site unwinding" (open question): the
  emitter's business; this task only provides `exit(record, line, ok,
  err)`.

## Spec issues found

## Review log
