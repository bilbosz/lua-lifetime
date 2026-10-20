# lua-lifetime

Owned and scoped objects with destructors for Lua. `x @ owner`, `x @
scope`, `cleanup !@ owner` hooks. Cleanup runs in a defined order when the owner dies
or the scope exits. Transpiles to Lua 5.1 / LuaJIT.

**Status:** the runtime, the transpiler and the command are implemented
(tasks 001 to 017 in [tasks/](tasks/)); the conformance suite runs every
example under Lua 5.1 and LuaJIT. The Teal front end, `teal-lifetime`,
is task 018: `.tlt` files transpile to Teal and run through `tl`.

## One-screen taste

```lua
local function serve(socket)
  local conn = Connection.open(socket) @ lifetime.scope      -- dies at block exit
  local buf = Buffer.new(64 * 1024) @ conn          -- dies with conn, or earlier if unreferenced
  local header = Slice.new(buf, 0, 512) @ (buf, conn)
  function() metrics.connections = metrics.connections - 1 end !@ conn
  handle(header)
end
-- at the end of serve: conn.__lifetime_destroy runs first, then its dependents,
-- most recently attached first: the hook, then header, then buf.
```

Lua source with `@`, the hook operator `!@` and `lifetime.scope` goes in,
plain Lua 5.1 comes out, and the generated code calls into the runtime
module `lifetime`, which is the language's own `lifetime` table. A
program that is not transpiled writes those calls itself, with the same
semantics (`docs/02-semantics.md`, "The library form"):

```lua
local lifetime = require("lifetime")

local function serve(socket)
  return lifetime.block(function(scope)
    local conn = lifetime.attach(Connection.open(socket), scope)   -- @ lifetime.scope
    local buf = lifetime.attach(Buffer.new(64 * 1024), conn)       -- @ conn
    lifetime.hook(function() metrics.connections = metrics.connections - 1 end, conn)  -- !@ conn
    return handle(buf)
  end)
end
```
Ownership is deterministic: anchored lifetimes, scope exit, `lifetime.destroy`,
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
| [examples/](examples/) | Example programs, each a conformance test; [examples/teal/](examples/teal/) the Teal ones |
| [tasks/](tasks/) | The backlog |

The model comes from [xd](https://github.com/bilbosz/xd), a Lua-like
language with lifetimes built in; the decisions this repository is built
on are `xd/docs/10-lua-lifetime-decisions.md` there. `xd` is the
pre-playground for the language; lua-lifetime carries the model to Lua as
it is today.

## teal-lifetime

The same for [Teal](https://github.com/teal-language/tl), from this
repository: `teal-lifetime-dev-1.rockspec` depends on `lua-lifetime` and
on `tl` and installs the Teal front end (`lifetime/teal.lua`) and the
declaration file of the runtime (`lifetime/init.d.tl`). A `.tlt` file is
Teal with the same additions; `lifetime build FILE.tlt -o OUT.tl` writes
plain Teal, every type written back as it was, and `lifetime run
FILE.tlt` type-checks and compiles it with `tl` and runs it on the
runtime:

```lua
local record Connection
  sock: Socket
end
local Connection_mt = {
  __index = Connection,
  __lifetime_destroy = function(self: Connection, reason: lifetime.Reason) self.sock:close() end
} as metatable<Connection>

local function serve(sock: Socket)
  local conn: Connection = Connection.open(sock) @ lifetime.scope
  local buf: Buffer = Buffer.new(64 * 1024) @ conn
  function(reason: lifetime.Reason) metrics.connections = metrics.connections - 1 end !@ conn
  handle(conn, buf)
end
```

See [docs/04-transpiler.md](docs/04-transpiler.md), "The Teal front
end", and [examples/teal/](examples/teal/).

## Running the tests

```
make test     # unit suite under every interpreter found (lua5.1, luajit), the conformance suite, then the Treflove trial (trial/treflove/, under luajit)
make lint     # luacheck
make bench    # benchmarks against plain Lua and against master (task 010)
```

Performance is a priority second only to correctness: code that does not
use the extension pays nothing, and what does is measured.

Both `lua5.1` and `luajit` are supported; at least one must be on `PATH`.
`luacheck` is needed for `make lint`. The Teal examples run on the
interpreters that have the `tl` module (`luarocks install tl`) and are
skipped with a note otherwise. See [CLAUDE.md](CLAUDE.md) for how work
happens in this repository.
