---
id: 014
title: Runtime: unwind scopes at the raise point from a message handler of `pcall` and `xpcall`
status: in-progress
depends: [012]
branch: task/014-unwind-at-raise
pr:
commits:
review:
---

## Goal

The runtime's `pcall` and `xpcall` unwind the scope records pushed since
the call began from a message handler, at the raise point, while the
frames that raised are still on the stack, so a dependent of an unwound
scope is reachable until its own destructor runs and the collector cannot
take it first. Today the unwinding runs after the original `pcall` has
returned `false`, and under a stressed collector `examples/unwind.lt`
prints `destroy a (unreachable)` before `destroy b (anchor)` on Lua 5.1
(task 008, spec issue 5). After this task the order and reasons every
example prints are unchanged and hold under that stress on both
interpreters; `coroutine.resume`, `coroutine.wrap`, `enter`, `exit` and
the fallback for a catch the runtime could not see are untouched.

Files: `lifetime/init.lua` (the section "The error path"),
`tests/test-scopes.lua` (or a new `tests/test-unwind.lua` listed in
`tests/run.lua`), `tests/conformance.lua` only if the child-process test
needs an environment argument on `conformance.check`,
`bench/bench-scopes.lua`, `bench/README.md`.

## Spec

- `docs/02-semantics.md`, "Scopes: `lifetime.scope`": "On the error path
  the runtime unwinds at the **raise point**: the scopes of every block
  between the raise and the `pcall`, `xpcall`, `coroutine.resume` or
  `coroutine.wrap` that catches the error die innermost first, each in
  its own reverse attachment order, while the frames that raised are
  still on the stack and before that call returns to its caller"; "The
  locals of those frames are alive while the scopes unwind, so a
  dependent of an unwound scope is reachable until its own destructor
  runs and the collector cannot take it first"; "An `xpcall` message
  handler runs first, at the same point, before any of them, as in Lua;
  what it returns is the error value the call returns, and a handler
  that raises gives Lua's `error in error handling` with the scopes
  unwound all the same"; the stack-overflow sentences ("One error keeps
  no order").
- `docs/02-semantics.md`, "Coroutines": "A coroutine that died of an
  error keeps its frames until it is collected, and the runtime holds it
  while it unwinds, so the dependents of those scopes are reachable until
  their destructors run, as they are for a `pcall`."
- `docs/02-semantics.md`, "Errors in destructors and `destroyerror`":
  "Every error raised while an error is already propagating (… any
  destructor running because a scope is unwinding) goes to
  `destroyerror` and the original error continues."
- `docs/02-semantics.md`, "Reachability is the collector's":
  "`collectgarbage("collect")` is the deterministic point."
- `docs/03-runtime.md`, "The scope stack and the error path": the
  mechanism ("`pcall(f, ...)` reads `S.stack.n` and calls the original
  `xpcall` on `f` with a handler of the runtime's; `xpcall(f, h)` does
  the same with a handler that wraps the user's `h`"; "Nothing is
  compared after the call"; "an error value that is not a string passes
  through the handler unchanged"; "Lua 5.1's `xpcall` passes no
  arguments to `f` (LuaJIT's does), so the runtime's `pcall` carries
  `...` to `f` itself; how is the implementation's choice, within the
  bound in "Performance""; "the user's `h` is called in protected mode";
  the overflow paragraph); and why `resume` and `wrap` need no change.
- `docs/03-runtime.md`, "Performance": the rows for `pcall`, `xpcall`
  and for `coroutine.resume`, a `coroutine.wrap` function; the bound in
  "Forced, and measured" ("`scope/pcall-empty` and `scope/pcall-error`
  within the threshold of `bench/README.md` against the catch-site
  runtime, with the arguments' passage on Lua 5.1 included, and
  `scope/resume-yield` unchanged").
- `docs/04-transpiler.md`, "The error path: unwinding at the raise
  point": the transpiler emits nothing for it.
- `docs/05-decisions.md`, "Scopes unwind at the raise point".
- Lua 5.1 reference manual, §5.1, `xpcall (f, err)`: `f` is called with
  no arguments; "In case of any error, `xpcall` … returns false plus the
  result from `err`"; §3.7, `lua_pcall`: `LUA_ERRERR`, "error while
  running the error handler function". LuaJIT, "Extensions":
  `xpcall(f, err, ...)` passes arguments.
- `CLAUDE.md`, rule 3 (a death by `reachable` is pinned with
  `collectgarbage("collect")`, never with timing), rule 5 (the cost is
  measured), rule 6 (the runtime holds no strong reference to a
  collectable dependent: the frames hold them, not the runtime).
- `bench/README.md`, "The threshold" and "Adding a benchmark".

## Acceptance criteria

- `pcall(f, ...)` calls the original `xpcall` with a runtime message
  handler; `xpcall(f, h)` calls it with a handler that calls `h` first,
  in protected mode, then unwinds every record above the depth read
  before the call, innermost first, with the error counted as
  propagating, then returns `h`'s result (or the error value unchanged
  when there is no `h`); the protected call returns what the original
  `xpcall` returned, nothing is compared or unwound after it (03, "The
  scope stack and the error path").
- Every existing example prints the same bytes as before: no
  `.expected` file changes; the conformance suite is green under both
  interpreters.
- `examples/unwind.lt` prints its `.expected` under
  `LUA_INIT='collectgarbage("setpause",10) collectgarbage("setstepmul",1000)'`
  on both interpreters, and a unit test runs the example that way in a
  child process under every interpreter `conformance.find_interpreters()`
  finds and compares the standard output with the `.expected` (test
  case 1).
- A dependent whose only reference is a local of a raising frame is
  alive when an inner record's destructor calls `collectgarbage("collect")`
  during the unwinding, and dies afterwards with reason `"anchor"` in its
  place in the order (test case 2; 02, "The locals of those frames are
  alive while the scopes unwind").
- A user `xpcall` handler runs before any record is unwound and its
  return value is the error value the call returns (test case 3); a user
  handler that raises gives `false, "error in error handling"` and the
  records are unwound all the same (test case 3b).
- An error value that is not a string (a table, a number, `nil`) comes
  out of `pcall` and of `xpcall` without a handler as the same value, a
  table by identity, and `pcall(error)` returns exactly two values,
  `false, nil` (test case 4).
- `pcall(f, ...)` passes every argument, trailing `nil`s included, on
  both interpreters: `select("#", ...)` inside `f` equals the count given
  (test case 5).
- A destructor error during the unwinding goes to `destroyerror` and the
  original error (or the user handler's result) comes out of the call;
  the existing cases in `tests/test-scopes.lua` ("a destructor error
  during the unwind goes to destroyerror", `examples/destroy_errors.lt`
  part 2) stay as they are (test case 6).
- The stack-overflow edge is documented in a test: after a Lua-stack
  overflow inside a protected call that pushed records, the call returns
  `false`, every record pushed inside is dead by the end of the next
  scope exit of the same coroutine, each dependent died once, in
  decreasing depth order, and the program continues; the test's comment
  records what each host did at the time (unwound in the handler, or
  ended with the host's message and finished at the next exit) (test
  case 7; 02, "One error keeps no order").
- The existing case "the wrappers allocate nothing: a loop of pcalls and
  xpcalls that raise through no scoped block" stays unchanged and green
  on both interpreters: the success path and the error path of `pcall`
  with up to one argument and of `xpcall` allocate nothing.
- The existing cases on hidden catches ("case 5a", "an exit that unwinds
  hidden records…"), on `coroutine.resume` and `coroutine.wrap` and on
  "requiring the runtime replaces exactly `pcall`, `xpcall`,
  `coroutine.resume` and `coroutine.wrap`; each returns or raises what
  the original does" stay unchanged and green.
- An argument error the originals raise (`pcall()` with no function,
  `xpcall(f)` with no handler on Lua 5.1) still comes out as the host's
  message, as the existing replacement test checks.
- `coroutine.resume`, `coroutine.wrap`, `lifetime.enter`, `lifetime.exit`
  and the per-coroutine stack push are not changed.
- The comments in `lifetime/init.lua`, "The error path", cite the new
  sentences of 03 and the decision "Scopes unwind at the raise point".
- `make test` green under both interpreters; `make lint` clean; `make
  bench BASE=master` twice: `scope/pcall-empty`, `scope/pcall-error`,
  `scope/pcall-args` (new) and `scope/resume-yield` not marked `SLOWER`
  in two consecutive invocations; the handoff reports their ns/op on
  both interpreters next to the stand-in's 53 against 59 ns.

## Test cases

Runtime API spelling as in `tests/test-scopes.lua`: `enter`, `exit`,
`attach`, `hold`, `new_logged(log, name)` whose destructor appends
`"<name> (<reason>)"`; `with_handler` installs a `destroyerror` that
records `tostring(obj) .. ": " .. e`.

1. **Stressed collector, child process.** For each interpreter found:
   run `sh -c "LUA_INIT='collectgarbage(\"setpause\",10)
   collectgarbage(\"setstepmul\",1000)' <interpreter> bin/lifetime run
   examples/unwind.lt"` with stdout to a file, as `conformance.check`
   runs an example. Standard output equals
   `examples/unwind.lt.expected` byte for byte up to its `!error:` line,
   so it begins
   ```
   destroy b (anchor)
   destroy a (anchor)
   pcall returned	false	examples/unwind.lt:27: boom
   ```
   and exit status is 1 with `lifetime: examples/unwind.lt:101: uncaught`
   on stderr. Before this task, `lua5.1` prints `destroy a (unreachable)`
   as its first line and never prints `destroy a (anchor)`.
2. **Reachability during the unwinding** (the sentence most likely to be
   misread: "a dependent of an unwound scope is reachable until its own
   destructor runs"; an implementation that unwinds after the call
   returns passes every other case and fails this one deterministically):
   ```lua
   local log = {}
   local ok, err = pcall(function()
       local outer = enter("t.lt:20")
       local a = attach(new_logged(log, "a"), false, outer)  -- a local of the raising frame, not held
       local inner = enter("t.lt:18")
       local b = attach(new_logged(log, "b", function()
           collectgarbage("collect")
           collectgarbage("collect")
       end), false, inner)
       error("boom", 0)
   end)
   ```
   `new_logged`'s third argument runs inside `b`'s destructor after it
   logs. Expected: `log == {"b (anchor)", "a (anchor)"}`, `ok == false`,
   `err == "boom"`, the stack depth back where it was. With the
   catch-site runtime the log is `{"b (anchor)", "a (unreachable)"}` (the
   two collects inside `b`'s destructor take `a`, whose frame is gone).
3. **User handler first; its result is the error value:**
   ```lua
   local log = {}
   local ok, err = xpcall(function()
       local s = enter("t.lt:30")
       hold(attach(new_logged(log, "x"), false, s))
       error("boom", 0)
   end, function(m)
       log[#log + 1] = "handler " .. m
       return "handled"
   end)
   ```
   Expected: `log == {"handler boom", "x (anchor)"}`, `ok == false`,
   `err == "handled"`.
   3b. The same with a handler that does `error("in handler", 0)`:
   `log == {"x (anchor)"}`, `ok == false`, `err == "error in error
   handling"` on both interpreters.
4. **Non-string errors unchanged:**
   ```lua
   local e = {}
   local ok, got = pcall(function()
       local s = enter("t.lt:40")
       hold(attach(new_logged(log, "x"), false, s))
       error(e)
   end)
   ```
   Expected: `ok == false`, `got == e` by identity (`rawequal`), `log ==
   {"x (anchor)"}`. Then `select("#", pcall(error))` is `2` and the
   second value is `nil`; `pcall(error, 42)` returns `false, 42` with
   `type(got) == "number"`; `xpcall(function() error(e) end, function(m)
   return m end)` returns `false, e`.
5. **Arguments through `pcall`:**
   ```lua
   local n, c
   local ok, r1, r2, r3 = pcall(function(a, b, cc, ...)
       n = select("#", a, b, cc, ...)
       return cc, b, a
   end, 1, nil, 3)
   ```
   Expected: `ok == true`, `n == 3`, `r1 == 3`, `r2 == nil`, `r3 == 1`,
   and `select("#", pcall(f, 1, nil, 3))` is `4`. Also `pcall(f, nil)`
   gives `n == 1`, `pcall(f)` gives `n == 0`, and `pcall(f, 1, 2, 3, 4,
   5, 6, 7, 8)` gives `n == 8` (more arguments than any fixed-arity
   fast path).
6. **Destructor error during the unwinding** (kept from task 003; the
   `xpcall` form added):
   ```lua
   with_handler(record, function()
       ok, err = xpcall(function()
           local s = enter("t.lt:60")
           hold(attach(new_logged(log, "x", function() error("x failed", 0) end), false, s))
           error("boom", 0)
       end, function(m) return "handled " .. m end)
   end)
   ```
   Expected: `routed == {"<tostring of x>: x failed"}`, `log == {"x
   (anchor)"}`, `ok == false`, `err == "handled boom"`; the `pcall` form
   returns `false, "boom"`.
7. **Stack overflow** (the edge; do not use an infinite `__index`
   chain, which crashes LuaJIT itself):
   ```lua
   local log, routed = {}, {}
   local function deep(n)
       local s = enter("t.lt:70")
       hold(attach(new_logged(log, tostring(n)), false, s))
       local r = 1 + deep(n + 1)
       exit(s, "t.lt:70")
       return r
   end
   local ok, err
   with_handler(function(obj, e) routed[#routed + 1] = e end, function()
       ok, err = pcall(deep, 1)
   end)
   local after = enter("t.lt:80")
   exit(after, "t.lt:80")
   ```
   Expected on both interpreters: `ok == false`; `err` contains `stack
   overflow` or equals `error in error handling`; after the `exit` of
   `after`, `#log` equals the greatest `n` entered, every entry is `"<n>
   (anchor)"`, the `n`s are strictly decreasing from the greatest to 1,
   no `n` appears twice, the stack depth is back where it was, and every
   entry of `routed` (if any) contains `stack overflow` or `error in
   error handling`. The test's comment records, per interpreter, whether
   the handler finished (`err` is the overflow message and the log was
   complete before `after`) or the fallback finished it. The probe of
   2026-10-10: Lua 5.1 refills the Lua stack for the handler (10 000
   nested calls ran inside one), LuaJIT leaves it about a dozen frames
   and a deeper handler ends with `stack overflow`; a destructor's own
   overflow under the cascade's `pcall` is caught there on both.

## Performance

Hot path: the success path of `pcall` and `xpcall` (one wrapper frame,
one field read, the original `xpcall`), and the error path, which now
runs the handler. Benchmarks in `bench/bench-scopes.lua`:
`scope/pcall-empty` and `scope/pcall-error` (update their rows in
`bench/README.md`: the call now goes through the original `xpcall` with
the runtime's handler, against the original `pcall`), and a new
`scope/pcall-args`: 10 `pcall`s of a three-argument function that
returns them, through the runtime's `pcall`, against the original
`pcall`, which is where Lua 5.1's argument passage shows. The bound: not
marked `SLOWER` against `master` in two consecutive `make bench
BASE=master` invocations on either interpreter; the stand-in measured
53 against 59 ns per protected call on Lua 5.1 and nothing measurable
on LuaJIT, so a mark is a finding to explain, not a budget to spend.
`scope/resume-yield` unchanged: the per-coroutine stack push stays as it
is. Must stay free: a chunk that calls no protected function pays
nothing new; `enter`/`exit` are untouched (`scope/loop-one-object`,
`scope/enter-exit-empty` unchanged); the plain-Lua rows keep ratio 1.0;
on LuaJIT the wrappers allocate nothing (its `xpcall` passes the
arguments itself); on Lua 5.1 a `pcall` with up to one argument
allocates nothing (the existing allocation test), and the mechanism for
more arguments is the implementer's.

## Out of scope

- Changing `coroutine.resume`, `coroutine.wrap`, `lifetime.enter`,
  `lifetime.exit`, the hidden-catch fallback in `exit`, or the
  per-coroutine stack table.
- Wrapping `error`, `coroutine.yield` or `coroutine.running`.
- Any `.expected` file; any change to `docs/` beyond none (the spec is
  on `master` before this task starts).
- Per-block `pcall` wrappers or any change to generated code.
- The traceback cosmetic of a `coroutine.wrap` re-raise carried by task
  012.
- Making a destructor's own stack overflow recoverable beyond what the
  cascade's protected call already does.

## Spec issues found

## Review log
