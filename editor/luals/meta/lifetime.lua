---@meta lifetime
-- editor/luals/meta/lifetime.lua: the `lifetime` module as the Lua
-- language server (LuaLS) sees it: the names of docs/02-semantics.md,
-- "The `lifetime` table" and "The library form", with their types. For a
-- program that requires the runtime as a library (Treflove's lua-lifetime
-- branch): point the server's `workspace.library` at this directory and
-- `require("lifetime")` resolves to these declarations. Never loaded at
-- run time: lifetime/init.lua is the runtime, and lifetime/init.d.tl the
-- same declaration for Teal.

---The `reason` a destructor or a hook is called with ("`__destroy` and
---reasons", rule 5): `"anchor"` when an anchor's death made the formula
---false (a scope exit included), `"destroy"` for `lifetime.destroy(obj)`,
---`"unreachable"` when the collector found the object, `"exit"` for the
---program-end sweep.
---@alias lifetime.Reason "anchor"|"destroy"|"unreachable"|"exit"

---A lifetime value ("The `lifetime` table"): a table with the private
---metatable `"lifetime"`, no fields, no lifetime of its own; what
---`lifetime.pin`, `lifetime.of` and `lifetime.reachable` give.
---@class lifetime.Lifetime

---A hook (`f !@ a`, `lifetime.hook`): a table with the private metatable
---`"hook"`; calling or indexing it raises. Dies by its anchors, by
---`lifetime.destroy` (runs it) or `lifetime.discard` (cancels it).
---@class lifetime.Hook

---A token (`lifetime.token([name])`): an anchor that names a span of time;
---no fields; `getmetatable(tok)` is the string `"token"`.
---@class lifetime.Token

---A block's scope record: what `lifetime.block` hands its function, the
---anchor for `lifetime.attach` and `lifetime.hook` inside it, and what
---`lifetime.enter` returns to generated code. Valid inside the block only.
---@class lifetime.Scope

---What `lifetime.attach` and `lifetime.hook` accept after the object: a
---live table or token, a scope record, a lifetime value, or
---`lifetime.reachable`.
---@alias lifetime.Anchor table|lifetime.Token|lifetime.Scope|lifetime.Lifetime

---The runtime of lua-lifetime (`require("lifetime")`).
---@class lifetime
---@field reachable lifetime.Lifetime The `reachable` term as a lifetime value: `lifetime.attach(x, lifetime.reachable)` releases `x` to the collector and registers it
---@field scope lifetime.Scope The marker the transpiler resolves in anchor position; a library-form program uses the record `lifetime.block` passes instead
local lifetime = {}

---`e @ a1, …, an`: give `obj` the lifetime of the conjunction of the
---anchors, with the implicit `reachable` term unless every anchor is a
---`lifetime.pin` value, and return `obj`. Replaces the object's formula; a
---dying or dead object cannot be moved.
---@generic T
---@param obj T
---@param ... lifetime.Anchor
---@return T
function lifetime.attach(obj, ...) end

---`f !@ a1, …, an`: a hook that calls `f(reason)` when any anchor dies,
---after that anchor's own destructor, among its other dependents by
---attachment order (most recently attached first). Pinned by its anchors.
---@param f fun(reason: lifetime.Reason)
---@param ... lifetime.Anchor
---@return lifetime.Hook
function lifetime.hook(f, ...) end

---`local name = f !@ a1, …, an`: `lifetime.hook` with a name for
---`tostring`, `lifetime.format` and the tombstone's message.
---@param name string
---@param f fun(reason: lifetime.Reason)
---@param ... lifetime.Anchor
---@return lifetime.Hook
function lifetime.named_hook(name, f, ...) end

---A block: calls `fn(scope, ...)` and returns what it returns. Objects
---attached to `scope` inside `fn` die when `fn` returns, newest first,
---with reason `"anchor"`; an error in `fn` unwinds them at the raise
---point. The record is dead once `fn` has returned.
---@generic R
---@param fn fun(scope: lifetime.Scope, ...: any): R?
---@param ... any Arguments passed to `fn` after the record
---@return R?
function lifetime.block(fn, ...) end

---A fresh token on the default lifetime; `name` is for display only.
---@param name string|nil
---@return lifetime.Token
function lifetime.token(name) end

---A lifetime value over the anchors without the implicit `reachable` term:
---`lifetime.attach(x, lifetime.pin(a))` is "alive while `a` is, referenced
---or not".
---@param ... lifetime.Anchor
---@return lifetime.Lifetime
function lifetime.pin(...) end

---`obj`'s current formula as a lifetime value, a snapshot. Raises on `nil`,
---a value or a dead object.
---@param obj table|function|thread|userdata
---@return lifetime.Lifetime
function lifetime.of(obj) end

---The liveness check that replaces `if x then`: `true` for an object that
---is alive or dying, `false` for a tombstone and for `nil` or `false`.
---@param x any
---@return boolean
function lifetime.alive(x) end

---Is `k` the key of the state record the runtime keeps inside every table
---it has seen? `pairs` and `next` show that field; a serializer or an
---emptiness check skips it with this test.
---@param k any
---@return boolean
function lifetime.is_state(k) end

---A fresh array of the live objects and hooks whose formula mentions
---`obj`, in attachment order.
---@param obj table|lifetime.Token
---@return (table|lifetime.Hook)[]
function lifetime.dependents(obj) end

---A string rendering of a lifetime value, an object's formula, a token or
---a hook: `(conn, reachable)`, `conn`, `reachable`, `token period`,
---`scope`, `hook cleanup`, `hook`.
---@param v any
---@return string
function lifetime.format(v) end

---End `obj`'s lifetime now, whatever its formula, with the full cascade:
---its destructor, then its dependents most recently attached first, then
---the tombstone. A no-op on `nil`, on a dead object and on a dying one.
---@param obj table|function|thread|userdata|nil
function lifetime.destroy(obj) end

---`lifetime.destroy` without `obj`'s own destructor (or a hook's function):
---on a hook this is "cancel".
---@param obj table|function|thread|userdata|nil
function lifetime.discard(obj) end

---Generated code: the prologue of a block that anchors to `lifetime.scope`,
---with the position of its `end`. A library-form program uses
---`lifetime.block`.
---@param position string
---@return lifetime.Scope
function lifetime.enter(position) end

---Generated code: the epilogue of such a block, with the exit's position.
---@param record lifetime.Scope
---@param position string
function lifetime.exit(record, position) end

---Tells the runtime the program is ending, so that the destructors the
---closing state runs report `"exit"`; an embedding host calls it from its
---quit path (LÖVE: `love.quit`).
---@param flag boolean
function lifetime.set_exiting(flag) end

return lifetime
