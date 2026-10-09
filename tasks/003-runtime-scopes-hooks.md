---
id: 003
title: Runtime: scope records, hooks
status: in-progress
depends: [002]
branch: task/003-runtime-scopes-hooks
pr:
commits:
review:
---

## Goal

The runtime provides what the emitter's block code will call:
`lifetime.enter(line)` / `lifetime.exit(record, line)` for scope records,
the per-coroutine scope stack and the replacements for `pcall`, `xpcall`,
`coroutine.resume` and `coroutine.wrap` that unwind it on the error path,
and `lifetime.hook(f, name, a1, …)` for hooks. Tests drive them by
hand, writing the block prologue and epilogue of `docs/04-transpiler.md`
as generated code would. Nothing in this task runs per function call:
there is no `caller` anchor and no depth counter (`docs/05-decisions.md`,
"`caller` is removed").

## Spec

- `docs/02-semantics.md`, "Scopes: `lifetime.scope`": a scope's dependents die at
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
- `docs/02-semantics.md`, "Scopes: `lifetime.scope`": the error path
  unwinds at the catch site, innermost first, before the catching call
  returns; a record a hidden catch left behind dies at the next `exit`
  that finds it above itself.
- `docs/02-semantics.md`, "Errors in destructors": while the runtime
  unwinds on an error, later destructor errors go to `destroyerror` and
  the original continues.
- `docs/02-semantics.md`, "Coroutines": a scoped block may yield; an
  error that ends a coroutine unwinds its scopes inside `resume`/`wrap`.
- `docs/03-runtime.md`, "Scope records" and "The scope stack and the
  error path": a record exists only for a block that anchors to it; the
  stack per coroutine; the four wrappers, allocation-free; `resume` swaps
  `S.stack`, `yield` is untouched.
- `docs/03-runtime.md`, "Performance": `enter`/`exit` is "one record (a
  small table) per entry"; a function call costs what it costs in Lua.

## Acceptance criteria

- `lifetime.enter(line)` returns a scope record with metatable `"scope"`
  and pushes it on the running coroutine's stack; `lifetime.exit(record,
  line)` pops it and runs the cascade with the record as root and no
  body, dependents in reverse attachment order with reason `"anchor"`,
  and `<where>` for their tombstones is `chunk:line` of the exit.
- After `require("lifetime")`, `pcall`, `xpcall`, `coroutine.resume` and
  `coroutine.wrap` are the runtime's: on an error they unwind every record
  pushed since the call began, innermost first, with destructor errors
  routed to `destroyerror`, and return or re-raise exactly what the
  originals would; `<where>` for an unwound record's dependents is
  `chunk:line` of the block's `end` passed to `enter`. The wrappers
  allocate nothing (`collectgarbage("count")` around a loop of `pcall`s
  that raise through no scoped block).
- `exit(record, line)` with records above `record` on the stack unwinds
  them first, innermost first, then pops and runs `record`'s cascade.
- `lifetime.scope` is the marker of `docs/03-runtime.md`, "Scope
  records": `tostring` gives `lifetime.scope`, indexing it raises
  `attempt to index lifetime.scope`, and `attach(x, false, lifetime.scope)`
  raises `attempt to anchor to lifetime.scope through a variable`.
- The runtime exports no `drop`, `caller` or `exit_main`; requiring it
  leaves `coroutine.create`, `coroutine.yield`, `coroutine.status`,
  `coroutine.running` and `error` untouched (`rawequal` before and after
  `require`).
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
5. Error path: `enter` two nested records with logging dependents `x`
   (outer) and `y` (inner), then `error("boom")` inside `pcall`; the log
   reads `y, x` before `pcall` returns `false, "…: boom"`, and the stack is
   back at its depth before the call. The same with `xpcall` and a
   handler that logs first: `handler, y, x`. A dependent whose body raises
   `"d"` during that unwind sends `"d"` to `destroyerror` and `"boom"`
   still comes out of `pcall`.
5a. Hidden catch: a `pcall` captured before `require` catches an error
   that left record `r` behind; the next `exit` of an outer record logs
   `r`'s dependents first, then its own.
5b. Coroutine error: a coroutine that `enter`s a record, attaches `z`,
   and raises; `coroutine.resume` returns `false` after `z` died; the
   main stack is untouched. The same through a `coroutine.wrap` function,
   which re-raises after `z` died.
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

Hot paths: `enter`/`exit` of a scope record (per block entry), the four
wrappers (per `pcall` or resume), hook creation. Benchmarks: a loop body
with one scoped object against hand-written cleanup; `enter`/`exit` of
an empty record in a loop; `pcall` of an empty function through the
wrapper against the original, both under `luajit -jv` to show the loop
still compiles. Must stay free: a function call, which the runtime never
sees; a block with no record, which never calls the runtime.

## Out of scope

- Generated code: task 006. Tokens, `pin`, sentinels: task 004.

## Spec issues found

## Review log
