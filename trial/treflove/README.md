# The Treflove trial (task 009)

The slice of Treflove that idioms A, B and C of
`xd/docs/notes/xd-in-treflove.md` describe, rewritten with lifetimes,
transpiled by this repository's transpiler and run under LuaJIT with
Treflove's own test doubles. It shows one `destroy(connection)` tearing
down the session tree in the order of `docs/02-semantics.md`, "Cascading
death", and an input unlinking itself from its form.

```
luajit trial/treflove/run.lua            # every scenario; exit status 1 on a mismatch
luajit trial/treflove/run.lua --print    # and print every log
luajit trial/treflove/run.lua teardown   # one scenario
```

`make test` runs it under `luajit` when `luajit` is on `PATH` and says it
skipped it otherwise. It passes under `lua5.1` too.

## Source

Copied from Treflove at commit
`459607486e82d57e075e1deeb9f3079aa04417f3`. The Treflove repository was
read, never modified.

| Kind | Files |
| --- | --- |
| Verbatim (`.lua`, byte for byte) | `utils/table.lua`, `utils/utils.lua`, `app/consts.lua`, `events/event-manager.lua`, `events/update-event.lua`, `events/keyboard.lua`, `networking/connection.lua`, `login/login-rp.lua`, `login/logout-rp.lua`, `game/game-data-rp.lua`, `data/upload-asset-rp.lua`, `data/download-asset-rp.lua`, `data/download-missing-assets-rp.lua`, `tests/lib/mocks.lua` |
| Edited (`.lt`; Treflove's file under `original/`, so `diff -u original/X.lua X.lt` shows every edit) | `utils/class.lt`, `networking/connection-manager.lt`, `networking/remote-procedure.lt`, `game/session.lt`, `login/login.lt`, `data/asset-manager.lt`, `ui/input.lt`, `ui/form-screen.lt`, `utils/backstack-manager.lt` |
| Excerpts (`.lt`, and the hand-written excerpt under `original/`) | `app/server.lt` (the `_sessions` table and the two connection callbacks of `Server:load`), `app/client.lt` (the two connection callbacks of `Client:load`) |
| Variant | `variants/unregistered/utils/class.lt`: `utils/class.lt` without the registration line, for the second run of test case 3 |
| Stubs (not Treflove code) | `stubs/`: the connector, `Screen`, `UserMenuScreen`, `LoginScreen`, `WaitingScreen`, `GameScreen`, `Asset`, `socket` |
| The trial itself | `harness.lua` (loading and driving the slice), `scenario.lt` (the scenarios), `run.lua` (instrumentation and the expected logs) |

`harness.lua` loads the slice into an environment of its own: the
transpiled copy (`X.lt`, else `X.lua`, else `stubs/X.lua`, every file
through `lifetime.cli.build`, a plain file transpiling to itself) or
Treflove's hand-written copy (`original/X.lua`, else `X.lua`, else
`stubs/X.lua`, loaded as they are). Both can live in one process, which
the benchmark needs. A client app and a server app are Treflove's
`mocks.make_app` with the real `UpdateEventManager`, `ConnectionManager`,
`AssetManager` and (client) `BackstackManager`; they talk over
`mocks.make_channel` pairs, back to back, as Treflove's
`tests/test-connection.lua` does. `love.data.hash`, `love.data.encode`,
`love.math.newRandomGenerator` and `love.filesystem` get deterministic
stand-ins, so the real login code of `login/login.lua` and
`login/login-rp.lua` runs.

## Every edit

Each edit carries a `-- lua-lifetime:` comment in the file.

- **`utils/class.lt`**: the instance metatable gets `__destroy =
  function(obj, reason) if obj.release then obj:release(reason) end end`
  (the note's line without `remaining`, which decision 10 removed), and
  `__call` registers every instance with `obj @ lifetime.reachable` right
  after `setmetatable`, before `init`. Nothing else.
- **`networking/connection-manager.lt`**: `ConnectionManager:remove` ends in
  `destroy(connection)` instead of `connection:release()`. The three table
  removals before it stay (see "What the note says that does not hold").
- **`networking/remote-procedure.lt`**: `RemoteProcedure:release` loses
  `self._connection = nil`; it is `self:stop()` only, so a second,
  redundant release works.
- **`login/login.lt`**: `LoginRp(...) @ self` and `LogoutRp(...) @ self`.
  `Login:release` with its two nested `release()` calls is **kept**, to
  show they are redundant, not wrong (lesson 4 reversed).
- **`game/session.lt`**: `Login(...) @ self` and `GameDataRp(...) @ self`
  (idiom A); `Session:release` is deleted. On the client the logged-in
  span is a token (idiom C; `docs/02-semantics.md`, "Tokens"): `_on_login`
  makes `lifetime.token("period") @ self`, keeps it in `self._period`, and
  anchors the user menu screen and the back entry to it; `_on_logout` is
  `destroy(self._period)` followed by `self._period = nil`, and shows
  `LoginScreen(self._login) @ self`.
  `self._user_menu_screen = nil` stays (a dead screen is a tombstone, not
  `nil`); `_backstack_cb` is gone.
- **`data/asset-manager.lt`**: `register_session` anchors the three
  procedures `@ session`; `unregister_session` is deleted; the three
  per-session tables are `setmetatable({}, {__mode = "kv"})` (see below).
- **`ui/input.lt`** (idiom B): `Input:init` attaches `function() if not
  form_screen:is_released() then form_screen:remove_input(self) end end
  !@ (form_screen, self)`. The hook is a function made into a hook by
  `!@`, pinned by its anchors; a plain function cannot be an anchored
  dependent yet (task 012), and needs not be.
- **`ui/form-screen.lt`**: a `release()` that sets `_is_released`, and
  `is_released()`. The input's hook gets only the reason, not the anchor
  that died (`docs/06-open-questions.md`, "Whether a hook or destructor
  learns which anchor died"), and the form's body runs before its
  dependents' hooks, so this flag tells the hook the form went first, as
  `examples/listeners.lt` does.
- **`utils/backstack-manager.lt`** (idiom C): `push(cb)` stores an entry
  `{cb = cb}`, hooks `function() table.remove(stack, find(stack, entry))
  end !@ entry` and returns the entry for the caller to anchor; `pop(cb)`
  is deleted; `back()` destroys the top entry before running its
  callback; `get_top()` returns the entry, not its callback.
- **`app/server.lt`, `app/client.lt`** (excerpts): `Session(connection) @
  connection`; the disconnect callbacks lose `session:release()` and keep
  the assignments that clear `_sessions[connection]`, `session` and
  `data`.

## What `class()` and `table.to_string` needed

- **`class()`**: the `__destroy` forwarder in `obj_mt` is what the slice
  needs, and all it needs. The registration of "Registration is `x @
  lifetime.reachable`" (`obj @ lifetime.reachable` in `__call`, after
  `setmetatable`, since the sentinel is armed at the first `@` that finds
  a `__destroy`, `docs/03-runtime.md`, "The sentinel") is needed by no
  object of the slice: every instance with a `release()` is anchored
  (`@ connection`, `@ self`, `@ session`, `@ period`) or used as an anchor
  (the connection, the form, the inputs) before it could be collected, and
  either makes the runtime see it. `utils/class.lt` keeps the line, as the
  decision says a class library does; `variants/unregistered/utils/class.lt`
  is the same file without it, the trial runs test case 3 with both, and
  the two differ (see "A collected session"). The merged index needed
  nothing: `table.merge` copies class tables, which the runtime never
  sees.
- **`table.to_string`**: nothing. It puts a key of type `table` in its
  third group and finds no `key_display` for it, so the state record
  under its private table key is skipped; the output for a table the
  runtime has seen equals the output for the same table unseen, and
  `table.from_string` reads it back (scenario `serializer`). The slice
  never serializes a seen table anyway: `Connection` serializes fresh
  request and response tables, and the server's `save.lua` holds plain
  data.
- **The rest of `utils/table.lua`**, measured but not used on a seen table
  in the slice: `table.copy` (and `table.deep_copy`, `cpairs`,
  `cipairs`) copies the state record field into the copy, which then
  carries another object's record; `table.is_empty` is `false` for an
  empty table the runtime has seen. `lifetime.is_state(k)` is the fix in
  each if a program ever copies or tests a seen table.

## The scenarios

Every log is compared whole with the sequence in `run.lua`. A line
starting with `>` is the statement that runs next, so each death sits
under the statement that caused it. The destructor lines come from
instrumentation in `run.lua`: each class's `release()` is wrapped to log
`Class:release(reason)` (or `Class destroyed (reason)` for a class that
has none: `Session`, `LoginScreen`, the test input), and a call made from
inside a logged method is indented, which shows `Login`'s nested calls
and each procedure's `stop()` reaching its connection. Each scenario ends
with two collections that must log nothing.

### The teardown (test case 1)

Written by hand from "Cascading death" before the first run (commit
`5e9e92c`), then compared. On the client, after a login,
`ConnectionManager:remove` runs `destroy(connection)`:

```
> client: connection_manager:remove(connection)
Connection:release(destroy)
Session destroyed (anchor)
UserMenuScreen:release(anchor)
  back stack depth 0
DownloadMissingAssetsRp:release(anchor)
  Connection:unregister_request_handler(DownloadMissingAssetsRp)
DownloadAssetRp:release(anchor)
  Connection:unregister_request_handler(DownloadAssetRp)
UploadAssetRp:release(anchor)
  Connection:unregister_request_handler(UploadAssetRp)
GameDataRp:release(anchor)
  Connection:unregister_request_handler(GameDataRp)
Login:release(anchor)
  LoginRp:release()
    Connection:unregister_request_handler(LoginRp)
  LogoutRp:release()
    Connection:unregister_request_handler(LogoutRp)
LogoutRp:release(anchor)
  Connection:unregister_request_handler(LogoutRp)
LoginRp:release(anchor)
  Connection:unregister_request_handler(LoginRp)
```

Traced against "Cascading death": the root's own body first
(`Connection:release`, reason `"destroy"`), then its only dependent, the
session (`Session(connection) @ connection`), body first, reason
`"anchor"`. The session's dependents in attachment order are `Login`
(Session:init), `GameDataRp`, then `UploadAssetRp`, `DownloadAssetRp`,
`DownloadMissingAssetsRp` (`AssetManager:register_session`), then the
period token (`_on_login`); most recently attached first gives the
period, whose dependents are the menu screen then the back entry: the
entry dies first and its hook removes it from the stack, so the menu
screen's body sees depth 0; then the three asset procedures newest first,
`GameDataRp`, and `Login`, whose body calls both procedures' `release()`
by hand while they are alive; then `Login`'s own dependents newest
first, `LogoutRp` then `LoginRp`, each running `release()` a second time.
Every `stop()` reaches the connection, which is dying, not dead: its body
has run, its fields are intact until it is tombstoned after the last
dependent. The server's teardown is the same without the period. After
it: the connection, session and login are tombstones (`lifetime.alive`
false), `app.session` is `nil` because the callback cleared it, the
channels are released, the connection manager is empty, and the asset
manager's weak entry still holds the dead session and procedure until two
collections clear it.

### Logging out (idiom C)

`backstack_manager:back()` destroys the entry (depth 1 to 0) and runs its
callback, `session:logout()`; the server answers; the client's
`_on_logout` runs `destroy(self._period)`: the entry is already dead and
skipped, the menu screen dies with depth 0, and `LoginScreen(...) @ self`
is shown. The disconnect then destroys the login screen first among the
session's dependents (the newest), before the procedures.

### The input and its form (test case 2)

| Run | Statement | Log | After |
| --- | --- | --- | --- |
| input first | `destroy(a)` | `TestInput destroyed (destroy) a`, then `FormScreen:remove_input(a)`: the hook runs after the input's body, while `a` is dying and findable | `inputs: {b}` |
| form first | `destroy(form)` | `FormScreen:release(destroy)` and nothing else: both hooks find the flag | `inputs: {a, b}`, both inputs alive with no hook left |
| one cascade | `destroy(period)`, with `form @ period` and each input `@ form` | `FormScreen:release(anchor)`, `TestInput destroyed (anchor) b`, `TestInput destroyed (anchor) a`, no `remove_input` | everything dead |

In the third run each input was anchored to the form after its own
`init` had attached the hook, so the form's list reads hook a, a, hook
b, b; newest first reaches `b` (whose hook then runs as `b`'s dependent
and finds the flag), then `b`'s hook again (dead, skipped), then `a`.

### A collected session (test case 3)

The server drops the session from `_sessions` and forgets the connection
without destroying it (the connection manager's three tables cleared by
hand), in a function of its own; then `collectgarbage("collect")` twice.
Lesson 1 of `xd/docs/09-lessons-from-treflove.md` ("held objects pin
what they reference") does not hold here: `Session @ connection` with
`session._connection` pointing back, and every procedure pointing at the
connection, is an ordinary cycle (decisions 3 and 4), and the first
collection takes all of it:

```
> collectgarbage("collect")
DownloadMissingAssetsRp:release(unreachable)
  Connection:unregister_request_handler(DownloadMissingAssetsRp)
DownloadAssetRp:release(unreachable)
  Connection:unregister_request_handler(DownloadAssetRp)
UploadAssetRp:release(unreachable)
  Connection:unregister_request_handler(UploadAssetRp)
GameDataRp:release(unreachable)
  Connection:unregister_request_handler(GameDataRp)
LogoutRp:release(unreachable)
  Connection:unregister_request_handler(LogoutRp)
LoginRp:release(unreachable)
  Connection:unregister_request_handler(LoginRp)
Login:release(unreachable)
destroyerror: trial/treflove/login/login.lt:50: attempt to index a dead table (table: 0x?, died at collector, unreachable)
Session destroyed (unreachable)
Connection:release(unreachable)
> collectgarbage("collect")
per-session entries left: 0, in channel released: true
```

The order is the collector's ("Reachability is the collector's": newest
first by creation, each object with a sentinel of its own dying first,
with `"unreachable"`). `class()` registers every instance before its
`init`, so the sentinels are armed in the constructors' order, parents
before children, and every procedure dies before its login, the login
before the session. Every `stop()` ran. `Login:release`'s nested call
then meets a tombstone, and the error goes to `destroyerror` because a
finalizer has no statement to raise at. The second collection clears the
weak per-session entries.

The same scenario with `variants/unregistered/utils/class.lt`, the class
library without the registration line:

```
> collectgarbage("collect")
Connection:release(unreachable)
Session destroyed (anchor)
DownloadMissingAssetsRp:release(anchor)
  Connection:unregister_request_handler(DownloadMissingAssetsRp)
... the rest of the teardown's sequence, ending with LoginRp:release(anchor)
> collectgarbage("collect")
per-session entries left: 0, in channel released: true
```

Without registration an instance is armed at its first `@`: a procedure
at its own `@ self`, an anchor at its first link. The tree is built
bottom up, so the login is armed after its procedures, the session after
its login, and the connection, first seen at `Session(connection) @
connection`, last of all. Its finalizer runs first, and its cascade takes
the whole subtree in ownership order with `"anchor"`, as `destroy` would;
the later finalizers find their objects dead. The nested `release()`
works again. Registering in the constructor is what turned the collected
order upside down.

## Findings

By lesson of `xd/docs/09-lessons-from-treflove.md` (lessons 1 to 5 and 8)
and by claim of the note.

1. **Lesson 1 reverses**, as the task expected: a child anchored to its
   parent with a back-reference is collectable as a cycle (test case 3).
   No tree needs an explicit root; `@ connection` is enough.
2. **Lesson 2 changes shape.** Death leaves no `nil` hole: a dead element
   is a tombstone in its array or table until something removes it. The
   back stack and the form's inputs remove theirs in a hook, by identity,
   while the element is dying, as the note says.
3. **Lesson 3 holds unchanged**: one `__destroy` per merged-index
   metatable. `FormScreen` (`Screen` + `KeyboardEventListener`) gets one
   `release()`; the `Input` mixin gets a hook in its `init` instead.
4. **Lesson 4 reverses for every death the program causes**, and for a
   collected subtree it depends on registration. Under `destroy`,
   `Login:release`'s nested calls reach live procedures and are redundant
   (test case 1). When the collector takes the whole subtree and the
   class library registers in its constructor, the procedures are
   finalized first and the nested call meets a tombstone (test case 3);
   the error names the line and the death, as lesson 4's "the error must
   name the field" asked, but it is an error. Without registration the
   same collection runs in ownership order and the nested call works. See
   "Spec issues found" in the task file.
5. **Lesson 5 holds**: a destructor run by the collector runs at an
   allocation point. The trial's harness meets it directly: a server app
   the benchmark first forgot to keep took its connections to the
   collector in the middle of the client's frames, with the global `app`
   naming the other side.
6. **Lesson 8 does not arise** in the slice: no `release()` moves anything.
7. **What the note says that does not hold here** (decision 8: tombstones,
   not `nil`):
   - "`_connections[connection]` ... are gone: a dead key or value is
     removed." No: `ConnectionManager:remove` keeps its three removals,
     and the disconnect callbacks keep clearing `_sessions[connection]`,
     `session` and `data`.
   - "the unregister_listener line [goes]: the weak entry clears itself".
     No: `Connection:release` keeps `unregister_listener`. A destroyed
     connection stays a key of the update manager's weak table until it
     is unreferenced and collected, and a frame in between would call
     `on_update` on the tombstone, which raises.
   - "unregister_session is deleted: the entries vanish with their key."
     Only once collected, and only with weak values too: Lua 5.1 and LuaJIT
     have no ephemerons (`docs/02-semantics.md`, "Host"), and each
     procedure refers back to its session through the connection's request
     handlers (`LoginRp.on_login` closes over the session), so a strong
     value pins its weak key forever. The tables are `__mode = "kv"`; the
     procedures stay alive through the handlers. Until the collector runs,
     `AssetManager`'s `_get_any_rp` (`next` over the table) can return a
     dead session's dead procedure; a client that reconnects and uploads
     before a collection would call it. A hook on the session that clears
     the three entries would remove that window.
8. **Idiom B's hook cannot always tell that the form is dying.** It knows
   the form went first only once the form's `release()` has run. When the
   form and its inputs die in one cascade and the cascade reaches an input
   before the form (both owned by one anchor, the form attached first: a
   scratch run of exactly that unlinked both inputs from the dying form
   before `FormScreen:release` ran), the hook unlinks from a form that is
   about to die. Harmless here, and not what the third run of test case 2
   shows, where the inputs are the form's own dependents and its body runs
   first. `lifetime.alive` is `true` for a dying object and nothing else
   tells; see "Spec issues found".
9. **Where Treflove calls `lifetime.set_exiting(true)`**
   (`docs/06-open-questions.md`, "How an embedding host announces program
   end", which names this task): in a `love.quit` callback registered by
   `App:register_love_callbacks` (`app/app.lua`), which LÖVE calls on every
   quit path, `App:quit`'s `love.event.quit` included, before it closes the
   state. Treflove defines no `love.quit` today. Not exercised: LÖVE is out
   of scope.

## Performance

`bench/bench-treflove.lua` (`bench/README.md`): both sides in one process,
the transpiled slice against Treflove's hand-written one, interleaved runs,
median of five, `make bench BENCH_FILES=bench/bench-treflove.lua
BASE=master`, two pairings per interpreter (this task changes nothing
under `lifetime/`, so the base side is the same code):

| Benchmark | LuaJIT 2.1 | Lua 5.1 |
| --- | --- | --- |
| `treflove/cycle`, ns per connect-login-disconnect cycle | 92 595 and 87 511; ratio to hand-written 1.67 and 1.61 | 247 433 and 240 867; ratio 2.00 and 2.24 |
| `treflove/dispatch-frame`, ns per frame over 10 connections | 702 and 760; ratio 0.93 and 1.00 | 2 514 and 2 278; ratio 1.09 and 0.99 |

- The hand-written cycle is about 55 µs under LuaJIT; the transpiled one
  about 90 µs. Timed by phase over 20 000 cycles (a scratch script with
  `os.clock`), the destroy cascades of the disconnect cost about 9 µs
  against 1 to 2 µs for the `release()` chain: about 0.4 µs for each of
  the 22 objects torn down (the period token and the back entry's hook
  included), close to the 350 ns per attach-and-destroy of
  `docs/03-runtime.md`, "Performance". Connect and login cost 15 to 30 µs
  more, where every
  object gets its state record, its sentinel and its anchor, and where
  the collector pays for the extra allocation.
- Registration in `class()` costs nothing measurable in the cycle: the
  same cycle without the registration line read 0.92 (LuaJIT) and 1.08
  (Lua 5.1) against with it, since every registered object of the cycle
  is anchored anyway; registration moves the first state record and the
  sentinel from the first `@` to the constructor.
- The event dispatch is Treflove's own code in both (no block of the slice
  anchors to `lifetime.scope`, so the transpiled `event-manager.lua` and
  `connection.lua` are their input): 0.93 to 1.09 across the runs, noise.
