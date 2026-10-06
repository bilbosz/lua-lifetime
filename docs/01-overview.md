# lua-lifetime: an overview

`lua-lifetime` brings owned and scoped objects with destructors to Lua 5.1
and LuaJIT, the way [Teal](https://github.com/teal-language/tl) brings
types: a transpiler turns Lua source with a few additions into plain Lua,
and a runtime module, `lifetime`, does the bookkeeping the generated code
calls into.

- **Transpiler.** Lua 5.1 syntax plus the postfix operator `@`, the
  keyword `defer`, the anchors `scope` and `caller`, and the `token`
  declaration goes in; plain Lua 5.1 that runs on Lua 5.1 and LuaJIT comes
  out. See [04-transpiler.md](04-transpiler.md).
- **Runtime.** `require("lifetime")` is the `lifetime` table of the
  language itself: `lifetime.pin`, `lifetime.reachable`, `lifetime.of`,
  `lifetime.alive`, `lifetime.dependents`, `lifetime.format`, and the
  builtins `destroy` and `discard`. It keeps every object's anchors and
  dependents, runs cascades in a defined order, and tombstones what died.
  See [03-runtime.md](03-runtime.md).
- **Not a language.** The language is Lua's; `lua-lifetime` adds ownership
  to it. `xd` is the language where lifetimes come first, and this
  repository carries `xd`'s model to Lua as it is today.

## A taste

```lua
local function serve(socket)
  local conn = Connection.open(socket) @ scope      -- dies at block exit
  local buf = Buffer.new(64 * 1024) @ conn          -- dies with conn, or earlier if unreferenced
  local header = Slice.new(buf, 0, 512) @ (buf, conn)
  defer function() metrics.connections = metrics.connections - 1 end @ conn
  handle(header)
end
-- at the end of serve: conn.__destroy runs first, then its dependents,
-- most recently attached first: the hook, then header, then buf.
```

`conn` is anchored to the block, so the block's exit, by any route,
destroys it. `buf` and `header` are anchored to `conn`: they cannot outlive
it, and the order in which they go is fixed. The hook is a dependent too.
Everything the block created is gone before the caller sees the return,
and the socket is closed by `Connection.__destroy`, not by a `close()` call
somebody has to remember. [02-semantics.md](02-semantics.md) states the
rules this example relies on.

## What is deterministic and what is not

Ownership is deterministic: anchored lifetimes, scope exits, `destroy`,
the cascade order, hooks and destructors run by them happen exactly where
the program says. Plain reachability is Lua's collector: an object nobody
anchored, or an anchored object that nothing refers to any more, dies when
the collector finds it, and `collectgarbage("collect")` is the point at
which a program may rely on that having happened. The repository
description says the same thing in one line: *cleanup runs in a defined
order when the owner dies or the scope exits*.

## Where the semantics come from

The model was designed for `xd`, in the `xd` repository, and tried against
Treflove, a LÖVE/LuaJIT game. What that trial taught, and what it changed,
are the eleven decisions in `xd/docs/10-lua-lifetime-decisions.md`. The
documents here are derived from `xd/docs/` with those decisions applied:

| Here | Derived from |
| --- | --- |
| [02-semantics.md](02-semantics.md), the spec | `xd/docs/02-lifetimes.md`, `03-destruction.md`, `04-syntax.md`, `06-hooks.md`, with the reversals of `10-lua-lifetime-decisions.md` applied section by section |
| [03-runtime.md](03-runtime.md) | decisions 1 to 4, 8 and 10 of file 10 |
| [04-transpiler.md](04-transpiler.md) | decisions 5, 6, 10 and 11 of file 10 |
| [05-decisions.md](05-decisions.md) | the style of `xd/docs/07-decisions.md`; the decisions this repository made itself |
| [06-open-questions.md](06-open-questions.md) | the "Open points for lua-lifetime" of file 10, plus what deriving the spec turned up |
| [07-conformance.md](07-conformance.md) | decision 9 of file 10 and `xd/examples/` |

The rule of precedence when a document here is unclear: file 10 of `xd`,
then the rest of `xd/docs/` where file 10 is silent, then the Lua 5.1
reference manual (and LuaJIT's documented extensions where LuaJIT differs),
and otherwise it is an open question to record, not to guess. Decisions of
file 10 are not changed here; a problem with one is written into
[06-open-questions.md](06-open-questions.md) and carried back to `xd` by a
human.

## Rocks

- `lua-lifetime`, this repository, module `lifetime`. Rockspec summary:
  *Ownership and destructors for Lua.* Targets Lua 5.1 and LuaJIT
  ([02-semantics.md](02-semantics.md), "Host").
- `teal-lifetime`, later, from the same repository: a second rockspec that
  depends on `lua-lifetime` for the runtime and on `tl`, with a Teal front
  end and Teal output; the transpiler core and the CLI are shared. Not
  created yet.
