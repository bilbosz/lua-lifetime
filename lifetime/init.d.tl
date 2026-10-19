-- lifetime/init.d.tl: the Teal declaration of the `lifetime` module
-- (task 018; docs/01-overview.md, "Rocks"; docs/02-semantics.md, "The
-- `lifetime` table"). A declaration, not a translation: the runtime is
-- lifetime/init.lua. `tl` finds this file next to it through the
-- `?/init.lua` entry of the path (`lifetime/init.d.tl`) from a checkout
-- and from the layout the teal-lifetime rockspec installs.
--
-- The generated Teal (lifetime/teal.lua, lifetime/emit.lua) begins with
-- `local lifetime = require("lifetime")` and calls `attach`, `hook`,
-- `named_hook`, `enter` and `exit` through locals; a program names the
-- rest, and one that is not transpiled writes `attach`, `hook`,
-- `named_hook` and `block` itself (docs/02-semantics.md, "The library
-- form").

local record lifetime
   -- A lifetime value ("The `lifetime` table": "a table with the private
   -- metatable `"lifetime"`: no fields, no lifetime of its own").
   record Lifetime
   end

   -- A hook, `f !@ a` ("Hooks: the `!@` operator"): "a table with the
   -- private metatable `"hook"`"; calling or indexing it raises.
   record Hook
   end

   -- A token, `lifetime.token([name])` ("Tokens: `lifetime.token`"): no
   -- fields; `getmetatable(tok)` is the string "token".
   record Token
   end

   -- A block's scope record, the value of `lifetime.enter`
   -- (docs/03-runtime.md, "Scope records") and what `lifetime.block`
   -- hands its function ("The library form").
   record Scope
   end

   -- The `reason` a destructor or a hook is called with ("`__destroy` and
   -- reasons", rule 5): "anchor" when an anchor's death made the formula
   -- false (a scope exit included), "destroy" for `lifetime.destroy(obj)`,
   -- "unreachable" when the collector found the object, "exit" for the
   -- program-end sweep.
   enum Reason
      "anchor"
      "destroy"
      "unreachable"
      "exit"
   end

   -- The `reachable` term as a lifetime value: `x @ lifetime.reachable`
   -- releases `x` to the collector and registers it.
   reachable: Lifetime

   -- The current block, as syntax: after `@` or `!@` the transpiler
   -- resolves the spelling to the block ("Scopes: `lifetime.scope`").
   -- Read anywhere else it is a marker that cannot be anchored to.
   scope: Scope

   -- A fresh token on the default lifetime; `name` is for display.
   token: function(name?: string): Token

   -- A lifetime value over the anchors without the implicit `reachable`
   -- term ("The implicit `reachable` term and `lifetime.pin`").
   pin: function(...: any): Lifetime

   -- `obj`'s current formula as a lifetime value, a snapshot.
   of: function(obj: any): Lifetime

   -- The liveness check ("Tombstones and `lifetime.alive`"): true for an
   -- object that is alive or dying, false for a tombstone, nil or false.
   alive: function(x: any): boolean

   -- Is `k` the key of the state record the runtime keeps inside every
   -- table it has seen? `pairs` shows that field; a serializer skips it.
   is_state: function(k: any): boolean

   -- A fresh array of the live objects and hooks whose formula mentions
   -- `obj`, in attachment order.
   dependents: function(obj: any): {any}

   -- A string rendering of a lifetime value, an object's formula, a token
   -- or a hook: `(conn, reachable)`, `conn`, `reachable`, `token period`,
   -- `scope`, `hook cleanup`, `hook`.
   format: function(v: any): string

   -- End `obj`'s lifetime now, with the full cascade ("Explicit
   -- destruction"); a no-op on nil, on a dead or a dying object.
   destroy: function(obj: any)

   -- The same, skipping `obj`'s own destructor (or a hook's function).
   discard: function(obj: any)

   -- `e @ a1, …, an` is `attach(e, a1, …, an)`, which returns `e`
   -- (docs/04-transpiler.md, "What `@` expands to"; the library form
   -- writes the same call). The implicit `reachable` term applies unless
   -- every anchor is a `lifetime.pin` value.
   attach: function<T>(obj: T, ...: any): T

   -- `f !@ a1, …, an` is `hook(f, a1, …, an)`; the function is called as
   -- `f(reason)`.
   hook: function(fn: function(reason: Reason), ...: any): Hook

   -- `local name = f !@ a1, …, an` is `named_hook("name", f, a1, …, an)`:
   -- the hook carries the name ("Named hooks").
   named_hook: function(name: string, fn: function(reason: Reason), ...: any): Hook

   -- The library form of a block ("The library form"): calls `fn(scope,
   -- ...)` and returns what it returns; the objects attached to `scope`
   -- die when `fn` returns, newest first, with reason "anchor".
   block: function(fn: function(scope: Scope, ...: any): any..., ...: any): any...

   -- Generated code (docs/04-transpiler.md, "Blocks"): the prologue of a
   -- block that anchors to `lifetime.scope`, with the position of its
   -- `end`, and the epilogue on every exit path, with the exit's position.
   enter: function(position: string): Scope
   exit: function(record: Scope, position: string)

   -- docs/03-runtime.md, "Program end": `lifetime run` sets the exit flag
   -- after the main chunk has returned; an embedding host calls it from
   -- its own quit path.
   set_exiting: function(flag: boolean)
end

return lifetime
