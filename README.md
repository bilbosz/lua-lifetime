# lua-lifetime

Owned and scoped objects with destructors for Lua. `x @ owner`, `x @
scope`, `cleanup !@ owner` hooks. Cleanup runs in a defined order when the owner dies
or the scope exits. Transpiles to Lua 5.1 / LuaJIT.

**Status:** bootstrapped, not yet implemented. The specification is
written; the backlog in [tasks/](tasks/) starts with task 001. Nothing
transpiles yet except a plain Lua file to itself.

## One-screen taste

```lua
local function serve(socket)
  local conn = Connection.open(socket) @ scope      -- dies at block exit
  local buf = Buffer.new(64 * 1024) @ conn          -- dies with conn, or earlier if unreferenced
  local header = Slice.new(buf, 0, 512) @ (buf, conn)
  function() metrics.connections = metrics.connections - 1 end !@ conn
  handle(header)
end
-- at the end of serve: conn.__destroy runs first, then its dependents,
-- most recently attached first: the hook, then header, then buf.
```

Lua source with `@`, the hook operator `!@` and `scope` goes in,
plain Lua 5.1 comes out, and the generated code calls into the runtime
module `lifetime`, which is the language's own `lifetime` table.
Ownership is deterministic: anchored lifetimes, scope exit, `destroy`,
the cascade order, hooks and destructors run by them. Plain reachability
is Lua's collector, with `collectgarbage("collect")` as the point a
program may rely on.

## Documents

| Document | What it covers |
| --- | --- |
| [docs/01-overview.md](docs/01-overview.md) | What lua-lifetime is, where the semantics come from, the relation to `xd` and `teal-lifetime` |
| [docs/02-semantics.md](docs/02-semantics.md) | **The spec** of the language extension |
| [docs/03-runtime.md](docs/03-runtime.md) | The design of the `lifetime` module |
| [docs/04-transpiler.md](docs/04-transpiler.md) | The grammar and the code generation |
| [docs/05-decisions.md](docs/05-decisions.md) | Decision log |
| [docs/06-open-questions.md](docs/06-open-questions.md) | Not decided yet |
| [docs/07-conformance.md](docs/07-conformance.md) | How the conformance suite relates to `xd/examples/` |
| [examples/](examples/) | Example programs, each a conformance test |
| [tasks/](tasks/) | The backlog |

The model comes from [xd](https://github.com/bilbosz/xd), a Lua-like
language with lifetimes built in; the decisions this repository is built
on are `xd/docs/10-lua-lifetime-decisions.md` there. `xd` is the
pre-playground for the language; lua-lifetime carries the model to Lua as
it is today. A later `teal-lifetime` rock will do the same for Teal from
this repository.

## Running the tests

```
make test     # unit suite under every interpreter found (lua5.1, luajit), then the conformance suite
make lint     # luacheck
make bench    # benchmarks against plain Lua and against master (task 010)
```

Performance is a priority second only to correctness: code that does not
use the extension pays nothing, and what does is measured.

Both `lua5.1` and `luajit` are supported; at least one must be on `PATH`.
`luacheck` is needed for `make lint`. See [CLAUDE.md](CLAUDE.md) for how
work happens in this repository.
