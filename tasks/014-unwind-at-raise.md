---
id: 014
title: Runtime: unwind scopes at the raise point from a message handler of `pcall` and `xpcall`
status: done
depends: [012]
branch: task/014-unwind-at-raise
pr: https://github.com/bilbosz/lua-lifetime/pull/42
commits: 2dea2913bfbbb433f6494ec81b6f76e424968c61
review: APPROVE (round 2)
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
   in place of `destroy a (anchor)` (its second line, after `destroy b
   (anchor)`).
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

1. **Settled (round 2): by the spec restatement on
   `spec/unwind-at-raise-hosts`, which records the measured Lua 5.1
   numbers as the bound; the mechanism stays.** The 5.1 cost bound is not
   met for the error path and the argument passage (03, "Performance",
   "Forced, and measured"). Measured with
   `make bench BASE=master`, two invocations on 2026-10-10 (branch/base,
   pairings in parentheses; ns per 10 calls): on Lua 5.1
   `scope/pcall-error` 1.227 (1.337, 1.131), 2072 vs 1689, then 1.165
   (1.163, 1.167), 2125 vs 1824: `SLOWER` twice, a finding;
   `scope/pcall-args` 2.008 (2.017, 1.999), 2272 vs 1132, then 1.866
   (1.907, 1.827), 2267 vs 1215: `SLOWER` twice, a finding;
   `scope/pcall-empty` 1.018 (0.955, 1.083), 1051 vs 1033, then 1.150
   (1.142, 1.159), 1117 vs 971: marked once in two, noise by the rule of
   `bench/README.md`, though an interleaved micro-benchmark puts the
   success path about 4% above master's; `scope/resume-yield` 1.007 and
   0.938. LuaJIT: no protected-call row marked (`pcall-empty` 0.891 and
   0.918, `pcall-error` 1.003 and 0.992, `pcall-args` 0.896 and 0.926,
   `resume-yield` 1.041 and 0.981).
   What costs, measured with interleaved micro-benchmarks on Lua 5.1:
   - `select("#", ...)`, about 25-30 ns per call, on every call: Lua 5.1
     has no way to tell `pcall(f)` from `pcall(f, nil)` without it (a C
     call or a table), and test case 5 requires the difference. The
     stand-in of 03 (`xpcall(f, h)` against `pcall(f)`) did not count
     arguments.
   - The handler on the error path: the host calls a message handler from
     C, a new VM entry, where the catch-site runtime made a Lua-to-Lua
     tail call (`caught`). This is the mechanism 03 prescribes.
   - The arguments: Lua 5.1 has no C function that calls a function with
     arguments under a message handler, so a Lua carrier takes them from
     upvalue slots and tail-calls `f`; the original `pcall` passed them in
     C. Clearing the slots (rule 6) is part of it.
   The mechanism chosen is the cheapest of those measured (a handler per
   depth cost about 18 ns more on the success path than leaving the depth
   in the wrapper's frame; a continuation that saves and restores a depth
   marker cost more than both). Whether the bound should be restated for
   Lua 5.1, or a different trade made, is the human's.

2. **Settled (round 2): by the spec restatement on
   `spec/unwind-at-raise-hosts`, which records the Lua 5.1 fallback and
   the callers it affects.** Lua 5.1: a C function given arguments is
   unwound at the catch site.
   A carrier that tail-calls a C function stays below it (5.1 runs a C
   function entered by a tail call above its caller's frame), so the C
   function's messages would name the carrier: its position for
   `error(m)`, `assert` or any `luaL_error`, and its local in "bad
   argument #1 to 'f'" (the original gives `'?'`). So a C function, a
   callable table or userdata given arguments goes to the original
   `pcall`, and the records it pushed are unwound when the original
   returns, as before this task. The records concerned are those pushed
   by Lua callbacks of the C function that raise through it: a `table.sort`
   comparator, a module chunk under `pcall(require, name)`, a `gsub`
   replacement function, a `__tostring` under `pcall(tostring, x)`. For
   those, on Lua 5.1 only, the raise-point guarantee of 02 ("a dependent
   of an unwound scope is reachable until its own destructor runs") does
   not hold. LuaJIT passes arguments itself and is exact everywhere. A way
   out, not taken here: a carrier compiled without line and local
   information (a binary chunk with the debug sections removed), whose
   frame gives no position and no name, so C functions could be carried
   too.

3. **Test case 4's `pcall(error, 42)` expectation contradicts both hosts.**
   `error(42)` adds the position of level 1 (empty under `pcall`) and in
   doing so turns the number into the string `"42"`; both originals
   return a string. The test follows the host (Lua 5.1 manual, §5.1,
   `error`) and checks `pcall(error, 42, 0)` for a number.

4. **Test case 7 exits only `after`, which cannot find the records left
   behind.** `after` is entered after the `pcall`, on top of them, and
   02's fallback is "the next scope exit of the same coroutine that finds
   it above itself". On LuaJIT, where the handler has no room, the
   records are below `after` and stay until an enclosing exit or program
   end. The test encloses the `pcall` in a record `outer` and checks that
   `after`'s exit leaves them and `outer`'s takes them, innermost first.

5. **Overflow: the handler declines rather than being cut.** 02 and 03 say
   that when the unwinding itself overflows "the host ends it". An end in
   the middle of the runtime's own code would lose a popped record or
   leave dependents marked dying for good, so on an overflow error the
   handler first checks for room (16 nested calls of a wide frame, in
   protected mode) and unwinds nothing without it: every record then
   stays whole for the fallback. Lua 5.1 refills the stack for a handler
   and unwinds everything there; LuaJIT never has the room. Separately,
   and not new: an overflow can strike inside a runtime function the
   program called at the limit (seen in `attach`/`link`), leaving the
   object unlinked and `busy` at 1 until the next operation; the test
   reads the greatest `n` from the log for that reason.

6. **A raising user handler is called once.** The original Lua 5.1
   `xpcall` calls a handler that raises again for every C level (about
   220 times) before `error in error handling`; the runtime's handler
   marks the call and re-raises at once, so `h` runs once on both hosts,
   as LuaJIT's original does. 02 pins the message, not the count.

7. **The user handler runs two frames above the raise point.** "The
   user's `h` is called in protected mode" puts the runtime's handler and
   the original `pcall` between `h` and the frames that raised, so
   `xpcall(f, debug.traceback)` shows two more lines and
   `debug.traceback(m, 2)` in `h` starts at `pcall`. `lifetime run`'s
   handler finds the raise point by probing once
   (`lifetime/cli.lua`, `raise_level`), so its report is unchanged.

8. **Not changed, recorded:** on Lua 5.1 the argument errors of the
   originals (`pcall()`, `xpcall(f)`) and `error(m, 2)` given to `pcall`
   carry the wrapper's position, as under the catch-site runtime of task
   003 (the original is called from the wrapper's frame); LuaJIT gives
   the caller's. A Lua function carried on Lua 5.1 is entered by a tail
   call, so `getfenv(2)` in it raises "no function environment for tail
   call" where the original gives `pcall`'s environment (checked). A
   memory error does not call a message handler on Lua 5.1 (`ldo.c`
   throws `LUA_ERRMEM` without one; read, not tested), so its records
   are left for the fallback. LuaJIT reports an `xpcall` that fails inside a
   message handler as `error in error handling` (its original does too);
   the runtime keeps that.

## Review log

### Round 1 review: REQUEST_CHANGES

Head `91b7921`. Correct on both hosts for every promise of 02 except
two findings; `examples/unwind.lt` stable under the eager collector on
both hosts (master fails on 5.1). F1 (blocking): on LuaJIT the first
protected call inside a destructor run by the handler's unwinding
returned `error in error handling` and a record it pushed was left
behind (the host's in-handler status). F2 (blocking): one case was
JIT-state dependent (4 of 25 LuaJIT runs). F3: C functions and
callables with arguments on Lua 5.1 unwind at the catch site; settled
by the spec restatement `spec/unwind-at-raise-hosts` (02, the host
limit). F4: task prose. F5: the Lua 5.1 cost (`pcall-args` 1.8-2.0,
`pcall-error` 1.12-1.23, `pcall-empty` 1.10-1.15); the reviewer found
no cheaper shape; settled by the same spec restatement (03, "Forced,
and measured"). F6: the first `xpcall` per stack table allocated.

### Round 2 review: APPROVE

Head `10d5c0b`. `make test` 360/360 under both interpreters,
conformance 75/75, trial matches; `make lint` clean; 50 LuaJIT and 20
Lua 5.1 unit runs green; bench on `bench-scopes.lua`: Lua 5.1 rows
inside the recorded bound, LuaJIT at parity, the F1 throw not visible.
F1 verified by the reviewer's own programs including recursion (a
destructor's `pcall` whose unwinding runs another destructor using
`pcall`) and by the three new tests; the throw is not
program-observable. One non-blocking finding: two comments cited the
task file where 03 and 05 now hold the sentences; applied by the
orchestrator in the approval commit after merging master `6cb54e1`.

### Round 2 (implementer)

Reviewer verdict on `91b7921`: REQUEST_CHANGES. Orchestrator rulings: F3
(spec issue 2) and F5 (spec issue 1) settled by the spec restatement on
`spec/unwind-at-raise-hosts`; the mechanism stays; LuaJIT's per-depth
handlers accepted, their comment now says they are bounded by the
deepest nesting reached.

- F1 (fixed): on LuaJIT a protected call made by a destructor that the
  handler's unwinding ran failed with `error in error handling`, and a
  record it pushed was left for the outer unwinding. LuaJIT marks the
  state while a message handler runs (`L->status = LUA_ERRERR` in
  `lj_err_run`) and runs no message handler until a caught throw clears
  the mark. `unwind_at_raise` now raises one error through the original
  `pcall` before it unwinds, on LuaJIT only, after the user's `h` has run;
  it runs only when records are to be unwound, so `scope/pcall-error`
  does not pay it. Three tests in `tests/test-unwind.lua` (both programs
  through `pcall`, through `xpcall` with a handler that returns, and an
  `xpcall` and a `pcall` with arguments inside a destructor); all three
  fail on LuaJIT with the reset turned off.
- F2 (fixed): the nested-`xpcall`-in-a-handler test accepts either host
  value for its first entry on LuaJIT (the host gives `inner h` when the
  inner raise runs on a trace), exact elsewhere and on Lua 5.1.
- F4 (fixed): test case 1's prose.
- F6 (fixed): every scope stack is made with `handler = false,
  handler_depth = false` (`main_stack`, `lifetime_resume`,
  `lifetime_wrap`), one shape, no key added by the first `xpcall`.
- Checks: `make test` and `make lint` green under both interpreters; 50
  runs of `luajit tests/run.lua unit`, 50 green (360/360 each). `make
  bench BASE=master BENCH_FILES=bench/bench-scopes.lua` twice,
  branch/base (ns per 10 calls): Lua 5.1 `pcall-empty` 1.116 (1094 vs
  980, not marked) and 0.950; `pcall-error` 1.145 (2098 vs 1833) and
  1.126 (2116 vs 1879), marked both times as in round 1 (settled);
  `pcall-args` 1.695 and 1.785, marked as in round 1 (settled);
  `resume-yield` 0.989 and 0.909. LuaJIT: `pcall-empty` 1.070 and 0.989,
  `pcall-error` 1.018 and 0.997, `pcall-args` 1.059 and 0.906,
  `resume-yield` 1.036 and 0.991; none marked. F1's throw runs only when
  records are unwound and does not show on `pcall-error`.
