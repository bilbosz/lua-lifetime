# Conformance against `xd/examples/`

Decision 9 of `xd/docs/10-lua-lifetime-decisions.md`: the conformance
suite is the contract. The programs in `xd/examples/` are run, transpiled,
under real Lua, and their output is compared with the `.expected` files.
Any example lua-lifetime cannot honour is a documented deviation here, not
a changed expectation in `xd`.

## The rule

An `xd` example is ported into `examples/` of this repository as
`NAME.lt` with `NAME.lt.expected`, under one of three headings:

1. **Ported unchanged.** The program uses no feature the decisions
   removed (the `all` and `any` constructors, the scope functions,
   nil-on-death, `remaining`) and pins no reachable death to a statement.
   Only the spelling changes: the scope function after `@` becomes
   `lifetime.scope`, an `all` over `a` and `b` becomes `(a, b)`. The `.expected`
   file is `xd`'s, byte for byte. `defer f @ a` becomes `f !@ a`, and a bare `defer f` becomes `f !@ lifetime.scope`.
2. **Rewritten around `collectgarbage`.** The program pins a death by
   `reachable` to a statement. The port inserts `collectgarbage("collect")`
   at that statement, and the `.expected` file is the one `xd` adopts for
   the rewritten example under its `/spec-change` pass (decision 9: both
   targets run the same file).
3. **Deviation.** The program depends on behaviour the decisions reverse
   in a way no rewrite preserves (a hook that decodes `remaining`,
   dependents destroyed before their anchor, a dead reference reading
   `nil`). The port shows the lua-lifetime behaviour, its `.expected` file
   differs from `xd`'s, and this page records what differs and which
   decision causes it.

Every ported example must pass under every interpreter the runner finds.
There is no expected-failure marker. The porting is task 008; this page
holds the headings and is filled in as each example is classified.

## Ported unchanged

| Example | Note |
| --- | --- |
| `block_exits` | Part 3 uses `goto`, which Lua 5.1 lacks (decision 1): it is a program in a string that runs only under LuaJIT, and under Lua 5.1 the example prints the lines LuaJIT prints, as task 006's `exit_paths.lt` does. |
| `uncaught_error` | The `!error:` line names the chunk `examples/uncaught_error.lt` (`examples/README.md`); the line number is kept. `log` is registered with `@ lifetime.reachable` so that the program-end sweep sees it ([05-decisions.md](05-decisions.md), "Registration is `x @ lifetime.reachable`"), and is a global where `xd` has a local, so that it is still referenced when the state closes: a main-chunk local is gone once the error has left the chunk, and the collector could take it earlier with `"unreachable"` (decision 2). `lifetime run` reports the error before the state closes, so on a merged stream `close log (exit)` follows the report; standard output is `xd`'s. |

## Rewritten around `collectgarbage`

| Example | Where the collect goes | Note |
| --- | --- | --- |
| `hand_off` | After the block, where `xd` found `c` unreachable at the block exit, and after `kept = nil`. | `lifetime.any(lifetime.scope(), lifetime.reachable)` is written `@ lifetime.reachable`: decision 7 says it "loses its meaning under decision 2 anyway". `lifetime.kind` is `lifetime.format`, which prints the same word. |
| `timers` | After `a = nil`. | A dead key no longer disappears from the queue (decision 8), so `after` hooks each entry to remove its own key while it is dying (idiom B of `xd/docs/09-lessons-from-treflove.md`). |

## Deviations

| Example | What differs | Decision |
| --- | --- | --- |
| `binding` | `any(all(model, widget), app)` is a token destroyed by a counting hook on `lifetime.pin(model, widget)` and on `app`; the formula prints as `(token binding, reachable)` and is not pruned; `app`'s destructor runs before the binding dies; no `remaining`; the dead binding is checked with `lifetime.alive`. | 7, 10, 8 |
| `cache_drop` | Collects after each drop; no `remaining`; the session's destructor runs before its entry `c`; `c` stays in the cache as a tombstone (`lifetime.alive` prints `false`, `xd` printed `nil`). | 2, 10, 8 |
| `cascade` | C++ order: in part 1 the bodies run `c, d, a, e, b`, in part 3 the registry before `e2`; `e @ any(a, c)` is the token idiom, and `e2` is pinned to its token, so `lifetime.dependents` lists it under the token; the scope is not stored in `here`; tombstones are checked with `lifetime.alive`; one collect shows the pinned `e2` survives. | 10, 7, 5, 8, 2 |
| `compose` | The request's destructor runs before `thing`'s; the spliced list renders `(app, request, reachable)`; `lifetime.kind` and `lifetime.anchor` are replaced by `lifetime.format`; `parent @ app` is `parent @ lifetime.pin(app)`, and a pinned object has no sentinel, so at program end `parent` dies after `app`, with `"anchor"`. | 10, 11, 7, 4 |
| `connection` | The connection's destructor (and the socket's close) runs before the buffers are freed. | 10 |
| `control_tree` | A collect after `button = nil`; the screen's destructor runs first, then the label, then the panel. | 2, 10 |
| `coroutines` | Collects after each drop; a collected suspended coroutine's objects die `"unreachable"` (each has a sentinel of its own); no hook on the coroutine `b` (only tables and tokens are anchors, [06-open-questions.md](06-open-questions.md), "Non-table anchors"); `any(w1, w2)` is a token destroyed by a counting hook on each worker's body scope; `lifetime.alive` for liveness. | 2, 7, 8 |
| `dead_cache` | `lookup` tests the entry with `lifetime.alive`; one line is added to show the tombstone still in the cache. | 8 |
| `dead_reference` | Every slot keeps the dead object as a tombstone; using it raises `attempt to index`/`assign to`/`call a dead table (<name>, died at <where>, <reason>)` instead of Lua's `nil` errors; the dead function of part 3 is a dead callable table, since a function cannot be an anchored dependent yet (task 012) and a call on a dead function is not caught ([06-open-questions.md](06-open-questions.md), "Non-table dependents after death"). | 8 ([05-decisions.md](05-decisions.md), "The dead metatable raises") |
| `defer` | A hook on `conn` runs after `conn`'s destructor, and the moved hook `keep` after the registry's at program end; hooks print the reason only; the discarded `rollback` prints as `dead hook rollback`. | 10, 8 |
| `destroy_errors` | `destroy(e)` runs `e`'s destructor before `f`'s, so `e`'s error propagates and `f`'s goes to `destroyerror`; the collector's destructor error goes to `destroyerror` and `collectgarbage` returns ([05-decisions.md](05-decisions.md), "Errors in finalizer-run destructors go to `destroyerror`"). | 10, 2 |
| `explicit_destroy` | The destroyed lock is checked with `lifetime.alive`, `false` where `xd` printed `nil`. | 8 |
| `generation` | The generation is a token, so the destroyed one prints `dead token generation`; a dying timer entry removes its own key; what the script spawns is pinned to the generation. | 8, 6, 4 |
| `hooks` | The hook on `lifetime.reachable` runs at a collect; no `remaining`; the destroyed hook prints `dead hook h`; the hook on `any(job1, job2)` hangs on the token of the counting-hook idiom. | 2, 10, 8, 7 |
| `listeners` | The array keeps a tombstone where `xd` had a `nil` hole (`ipairs` sees 2); collects after each drop, twice before counting the weak table; the hook on `(form, item)` cannot read `remaining` and runs after the destructor of the side that died, so the form's destructor sets a flag the hook reads; `b`'s destructor runs before its hook. | 8, 2, 10 |
| `move` | The root's destructor runs before the child's at scope exit; after the release, the collect finalizes the child first (its own sentinel is newer), both `"unreachable"`; formulas render with `reachable`. | 10, 2, 4 |
| `pinned_parent` | Hazard 1 is gone: cases 1 and 2 die at a collect instead of living to program end, and the printed messages say so; case 3 is case 1; in cases 2 and 4 the owner's destructor runs first; nothing is left for the program-end sweep. | 3, 4, 2, 10 |
| `release_chain` | One `destroy` runs the chain body first: connection, session, `data_rp`, login, `logout_rp`, `login_rp`; `Connection:release` sees the session alive (lesson 4 reversed); the connection is `dead connection`; the weak-key table empties after `conn = nil` and two collects. | 10, 8, 2 |
| `scope_passing` | A scope cannot be passed: `make_counter` returns the counter and the receiver anchors it to `lifetime.scope`; the counter is a callable table (a function cannot be an anchored dependent yet, task 012); the escaped counter is a tombstone whose call raises. | 5, 8 |
| `shared_channel` | `any(producer, consumer)` is a token destroyed by a counting hook on each; the formula prints `(token channel, reachable)` instead of the pruned `anchor`; liveness is `lifetime.alive`, so the dead view prints `false`. | 7, 8 |
| `weak_tables` | Collects after each drop, twice before each count of a weak table; Lua 5.1 and LuaJIT have no ephemerons, so in part 3 the value keeps its key alive through the weak-key table and both die in the program-end sweep with `"exit"`. | 2, 1 |
| `workers` | `any(...)` over the workers is the token idiom; the formula stays `(token channel, reachable)`; the empty-list error is `lifetime.pin`'s; at block exit `w3`'s destructor runs before the channel closes; the workers hang on a token anchored to the block, since the scope cannot be stored. | 7, 10, 5, 8 |
| `caller` | Not ported: the `caller` anchor does not exist here. The receiver anchors what a function returns (`local x = f() @ lifetime.scope`). | [05-decisions.md](05-decisions.md), "`caller` is removed" |

Decision numbers refer to `xd/docs/10-lua-lifetime-decisions.md`. Each
example's header comment says the same in more detail.

## Examples to classify (task 008)

None: every example of `xd/examples/` is listed above.
