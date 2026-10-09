-- lifetime/init.lua: the runtime, `require("lifetime")`.
--
-- This is the `lifetime` table of docs/02-semantics.md ("The `lifetime`
-- table") and the bookkeeping behind it, designed in docs/03-runtime.md:
-- state records inside the anchor, the cascade in the order of decision
-- 10, tombstones, the newproxy sentinel, scope records, hooks and
-- tokens.
--
-- Task 002: anchors, the state record, `attach`, `destroy`, `discard`,
-- the two-phase cascade, tombstones, `destroyerror`, lifetime values
-- (`of`, `reachable`, `format`), `dependents`, `is_state`. Task 003:
-- scope records (`enter`, `exit`), the per-coroutine scope stack and the
-- replacements for `pcall`, `xpcall`, `coroutine.resume` and
-- `coroutine.wrap` that unwind it on the error path, the `lifetime.scope`
-- marker, hooks (`hook`) and the anchor's `strong` table. Task 004:
-- tokens (`token`), `pin`, `alive`, the `newproxy` sentinel that runs a
-- cascade when the collector finds an object, and the exit flag.
--
-- Rules this file keeps (CLAUDE.md, "Technical decisions"; rule 6):
--
-- * State lives inside the object, under the private key STATE. There is
--   no side table keyed by an object.
-- * An anchor's `deps` table is weak-valued: the runtime never keeps a
--   dependent alive. Its `strong` table holds what the language says the
--   anchor keeps alive (hooks and pinned dependents) and nothing else. A
--   dependent's record holds its anchors strongly.
-- * Dependents are walked by a numeric loop over the sequence range
--   `seq - 1 .. lo`, newest first, skipping holes; never `ipairs`, never
--   a sort. Holes are compacted on `link`, amortised, never during a
--   destroy phase.
-- * Nothing here keeps a strong reference to a user object except a
--   dependent's record (its anchors), lifetime values (their anchors),
--   an anchor's `strong` table (its hooks and pinned dependents) and the
--   scope stacks (the active scope records), all of which the spec makes
--   strong. A sentinel's metatable holds its owner, and the owner holds
--   the sentinel: an ordinary cycle the collector takes as a whole. The
--   runtime itself holds a sentinel only while it is disarmed (`spare`)
--   or for the moment between the collector's call and the cascade
--   (`queue`).

local lifetime = {}

local type, next, rawget, rawset, rawequal, select, tostring, pcall, error = type, next, rawget, rawset, rawequal, select, tostring, pcall, error
local getmetatable, setmetatable = getmetatable, setmetatable
local debug_getmetatable, debug_setmetatable, debug_getinfo, debug_traceback = debug.getmetatable, debug.setmetatable, debug.getinfo, debug.traceback
local concat = table.concat
local newproxy = newproxy

-- docs/03-runtime.md, "The state of an object": "The field's key is one
-- table the runtime creates when it is loaded and never hands out".
local STATE = {}

-- The dependents table of an anchor is weak-valued (docs/03-runtime.md,
-- "The state of an object"; CLAUDE.md, rule 6).
local WEAK_VALUES = {__mode = "v"}

-- An anchor's sequence range is checked for holes when it reaches
-- `limit` slots; compaction then renumbers when holes outnumber live
-- entries (docs/03-runtime.md, "The state of an object") and sets the
-- next limit to twice the live count, so the scan is amortised over the
-- links that grew the range.
local MIN_LIMIT = 16

-- An emptied dependents list, kept for the next anchor's first link: the
-- `deps` and `strong` tables of a scope record whose exit left both
-- empty. A loop body that anchors to its block then allocates no list per
-- iteration (docs/03-runtime.md, "Performance": "a block with a scope
-- record: one record (a small table) per entry"). Empty tables refer to
-- nothing, so this holds no user object (CLAUDE.md, rule 6).
local spare_deps, spare_strong = false, false

-- The phase guard (docs/03-runtime.md, "The cascade", "Phase guard").
-- `phase_depth` counts the destroy phases running; `phase_id` is the id
-- of the innermost one (0 when none runs); `phase_counter` hands out ids.
-- An object's record stores in `phase_id` the id of the phase during
-- which the runtime first saw it (0 outside any phase), which is "the
-- per-phase set of objects created during the phase" without a set: an
-- object is exempt from "No moves during destruction" when its id is the
-- innermost phase's. While the object is dying the same field holds the
-- id of the cascade that decided its death, and 0 once that cascade has
-- reached it, so a second path to it (a cycle of anchors) skips it.
local phase_depth, phase_id, phase_counter = 0, 0, 0

-- The error rule of one cascade (docs/02-semantics.md, "Errors in
-- destructors and `destroyerror`"): whether an error is held, and which.
-- Saved and restored around a nested cascade, which is one of its own.
local held, held_error = false, nil

-- The scope stack of the running coroutine (docs/03-runtime.md, "The
-- scope stack and the error path": "`S.stack` is the stack of the
-- running coroutine, and the main thread's is the initial one"), a
-- plain table `{n = depth, [1 .. n] = records}`. An upvalue rather than
-- a field, so `enter` and `exit` read it without a table lookup; the
-- `coroutine.resume` and `coroutine.wrap` replacements swap it for the
-- duration of a resume ("Error path" below).
local main_stack = {n = 0}
local stack = main_stack

-- Unwinds the records of a stack above a depth on the error path;
-- defined with the scope records below, called from the cascade where
-- the runtime's own protected calls catch an error.
local unwind

------------------------------------------------------------------------
-- Sentinels
------------------------------------------------------------------------

-- docs/03-runtime.md, "The sentinel": "`newproxy(true)` returns a
-- zero-size userdata with its own fresh metatable ... The runtime stores
-- the owning table in that metatable (`getmetatable(proxy).owner = obj`)
-- and sets `__gc` to the finalizer; the table holds the proxy in its
-- state record." The owner's record holds it in `reachable` (an object
-- with the `reachable` term and something to run at collection: the term
-- is backed by the sentinel, so the field is `false` for no term, `true`
-- for the term alone, or the proxy), and a scope record in `sentinel`.
-- The cycle proxy -> metatable -> owner -> record -> proxy is an ordinary
-- one: when the owner becomes unreachable the collector resurrects all of
-- it for the finalizer.
--
-- Finalizers run in reverse creation order of the proxies (both hosts;
-- docs/02-semantics.md, "Host"), which is "newest first" of
-- "Reachability is the collector's" when the proxies are in the order of
-- the `@` that made each object need one. A proxy is allocated lazily, on
-- the first `@` that makes its owner need one, and is kept for the
-- owner's whole life ("never again for the same object").
--
-- When an owner dies by a cascade its proxy is disarmed (`owner = nil`),
-- so the finalizer finds nothing to do. A disarmed proxy is kept for the
-- next owner (`spare`) only when no proxy has been handed out since it
-- was (`newest[1]` is still it), so that handing it out again keeps the
-- proxies in the order of the `@`s, exactly as a fresh one would; a loop
-- body that owns one object then reuses one proxy and allocates none.
-- `newest` is weak-valued: it keeps no proxy alive, and a proxy the
-- collector has scheduled for finalization is cleared from it (a
-- finalized userdata is removed from weak values on both hosts), so such
-- a proxy is never reused. Every other disarmed proxy also loses its
-- `__gc`, so the collector frees it without a finalizer call.
local newest = setmetatable({}, WEAK_VALUES)
local spare = false

-- The finalizer, defined with the cascade below.
local finalize

-- A sentinel for `owner` (docs/03-runtime.md, "The sentinel").
local function new_sentinel(owner)
    local p = spare
    if p then
        spare = false
        getmetatable(p).owner = owner
        return p
    end
    p = newproxy(true)
    local mt = getmetatable(p)
    mt.__gc = finalize
    mt.owner = owner
    newest[1] = p
    return p
end

-- Disarm the sentinel of an owner that died by a cascade.
local function drop_sentinel(p)
    local mt = getmetatable(p)
    mt.owner = nil
    if newest[1] == p then
        spare = p
    else
        mt.__gc = nil
    end
end

-- docs/02-semantics.md, "Reachability is the collector's": "A destructor
-- run by the collector runs at an arbitrary allocation point, in the
-- middle of whatever the program was doing." That includes the runtime's
-- own allocations: `attach` validates its anchors, then allocates (a
-- state record, a dependents list, a proxy) and links. A cascade run in
-- between could kill an anchor already validated and leave the object
-- linked to a tombstone. `busy` counts the runtime operations that
-- validate and then mutate across an allocation; while it is not 0 the
-- finalizer queues its proxy (holding it, and so its owner, for that
-- moment), and the operation drains the queue when it ends, so the
-- cascade runs as if the collector had found the object just after it.
local busy = 0
local queue, queue_head, queue_tail = {}, 1, 0

-- Defined with the finalizer below.
local drain

------------------------------------------------------------------------
-- State records
------------------------------------------------------------------------

-- docs/03-runtime.md, "The state of an object". The record's fields are
-- fixed, so LuaJIT keeps one table shape; `false` stands for the
-- design's `nil`. The formula is `n` anchors in the array part as pairs
-- `[2i - 1] = anchor, [2i] = the sequence number under which this object
-- sits in that anchor's `deps``, plus `reachable`, the implicit term:
-- `false` without it, `true` with it, or the object's sentinel when the
-- object has it and something to run at collection ("Sentinels" above).
-- `deps` is this object's side as an anchor, created on the first link
-- (`link`): the weak-valued table of dependents by sequence number, which
-- also carries the counters `seq`, `lo` and `limit` of the design, so
-- that a record has eight fields and an object that is never an anchor
-- pays for none of them. `name`, `where` and `reason` are what the
-- tombstone's message needs.
local function new_state(obj)
    local st = {
        false,
        false,
        n = 0,
        reachable = true,
        deps = false,
        phase = false,
        phase_id = phase_id,
        name = false,
        where = false,
        reason = false
    }
    rawset(obj, STATE, st)
    return st
end

-- docs/02-semantics.md, "The `lifetime` table": `lifetime.is_state(k)` is
-- `true` when `k` is the key of the state record, `false` for anything
-- else.
function lifetime.is_state(k)
    return rawequal(k, STATE)
end

------------------------------------------------------------------------
-- Lifetime values
------------------------------------------------------------------------

-- docs/02-semantics.md, "The `lifetime` table": "A lifetime value is a
-- table with the private metatable `"lifetime"` ... It holds its anchors
-- strongly ... It is an immutable snapshot ... `==` on two values
-- compares structure." Anchors in the array part `[1 .. n]`, the term in
-- `reachable`.
local VALUE_MT = {__metatable = "lifetime"}

local function is_value(v)
    return getmetatable(v) == "lifetime" and debug_getmetatable(v) == VALUE_MT
end

local function new_value(n, reachable)
    return setmetatable({n = n, reachable = reachable}, VALUE_MT)
end

local function contains_all(x, y)
    for i = 1, x.n do
        local a, found = x[i], false
        for j = 1, y.n do
            if rawequal(y[j], a) then
                found = true
                break
            end
        end
        if not found then
            return false
        end
    end
    return true
end

-- Structure: the same term and the same anchors (a conjunction, so the
-- order of the anchors does not matter).
VALUE_MT.__eq = function(x, y)
    return x.reachable == y.reachable and contains_all(x, y) and contains_all(y, x)
end

-- docs/02-semantics.md, "The `lifetime` table": `lifetime.reachable`, the
-- `reachable` term as a lifetime value.
local REACHABLE = new_value(0, true)
lifetime.reachable = REACHABLE

------------------------------------------------------------------------
-- Tombstones
------------------------------------------------------------------------

-- `tostring(obj)` as it reads without a metatable: `table: 0x…`.
local function raw_tostring(obj)
    local mt = debug_getmetatable(obj)
    debug_setmetatable(obj, nil)
    local name = tostring(obj)
    debug_setmetatable(obj, mt)
    return name
end

-- docs/02-semantics.md, "Named hooks": "`tostring(hook)` is `hook NAME`
-- ... A hook bound any other way ... is anonymous and `tostring` gives
-- `hook: 0x…`". A hook's record keeps the name it was created with in
-- `name` (fixed at creation, "storing the hook somewhere else later does
-- not rename it"), and the text is built when asked for, so a hook costs
-- no string per creation (docs/03-runtime.md, "Hooks": "Naming costs one
-- string constant per creation site and nothing per call").
local function hook_name(h, st)
    local name = st.name
    if name then
        return "hook " .. tostring(name)
    end
    -- `table: 0x…` without the `table: `.
    return "hook: " .. raw_tostring(h):sub(8)
end

-- docs/02-semantics.md, "Tokens: `lifetime.token`": "`tostring(tok)` is
-- `token NAME`, or `token: 0x…` without a name, and `lifetime.format` and
-- the tombstone's message use the same text." A token's record has the
-- field `token` and keeps the name it was created with in `name`.
local function token_name(t, st)
    local name = st.name
    if name then
        return "token " .. name
    end
    return "token: " .. raw_tostring(t):sub(8)
end

-- `<name>` of a tombstone: `tostring(obj)` before death
-- (docs/02-semantics.md, "Tombstones"). An object whose metatable had a
-- `__tostring` had its name captured when it started dying (`decide`);
-- for any other table `tostring` gives `table: 0x…`, which depends only
-- on identity, so it is computed here, on the error path, instead of
-- allocating a string per tombstone. A hook's record has the field `fn`
-- (`false` once dead) and renders through `hook_name`; a token's has
-- `token` and renders through `token_name`.
local function name_of(obj, st)
    if st.fn ~= nil then
        return hook_name(obj, st)
    elseif st.token then
        return token_name(obj, st)
    end
    local name = st.name
    if name then
        return tostring(name)
    end
    return raw_tostring(obj)
end

-- `attempt to <verb> a dead table (<name>, died at <where>, <reason>)`
-- (docs/02-semantics.md, "Tombstones and `lifetime.alive`").
local function dead_message(obj, st, verb)
    return "attempt to " .. verb .. " a dead table (" .. name_of(obj, st) .. ", died at " .. tostring(st.where) .. ", " .. tostring(st.reason) .. ")"
end

-- docs/03-runtime.md, "The tombstone": `__index`, `__newindex` and
-- `__call` raise; `__tostring` renders `dead <name>`; `__metatable =
-- "dead"`; no `__eq`.
local DEAD_MT = {__metatable = "dead"}
DEAD_MT.__index = function(obj)
    error(dead_message(obj, rawget(obj, STATE), "index"), 2)
end
DEAD_MT.__newindex = function(obj)
    error(dead_message(obj, rawget(obj, STATE), "assign to"), 2)
end
DEAD_MT.__call = function(obj)
    error(dead_message(obj, rawget(obj, STATE), "call"), 2)
end
DEAD_MT.__tostring = function(obj)
    return "dead " .. name_of(obj, rawget(obj, STATE))
end

------------------------------------------------------------------------
-- Runtime objects: hooks, scope records, the `lifetime.scope` marker
------------------------------------------------------------------------

-- docs/02-semantics.md, "Hooks: the `!@` operator": "A hook is a table
-- with the private metatable `"hook"`: `getmetatable(h) == "hook"`;
-- calling or indexing it raises `attempt to call a hook value` /
-- `attempt to index a hook value`." Assigning a field is indexing, as
-- for a token ("Tokens": "indexing or assigning a field raises `attempt
-- to index a token value`"). The hook table holds nothing but its state
-- record, so every user index reaches these.
local HOOK_MT = {__metatable = "hook"}
HOOK_MT.__index = function()
    error("attempt to index a hook value", 2)
end
HOOK_MT.__newindex = HOOK_MT.__index
HOOK_MT.__call = function()
    error("attempt to call a hook value", 2)
end
HOOK_MT.__tostring = function(h)
    return hook_name(h, rawget(h, STATE))
end

-- docs/02-semantics.md, "Tokens: `lifetime.token`": "It has no fields:
-- indexing or assigning a field raises `attempt to index a token value`.
-- `getmetatable(tok)` is the string `"token"`." The token table holds
-- nothing but its state record, so every user index reaches these.
local TOKEN_MT = {__metatable = "token"}
TOKEN_MT.__index = function()
    error("attempt to index a token value", 2)
end
TOKEN_MT.__newindex = TOKEN_MT.__index
TOKEN_MT.__tostring = function(t)
    return token_name(t, rawget(t, STATE))
end

-- docs/03-runtime.md, "The state of an object": scope records are
-- runtime tables with "a private metatable (`__metatable` set to ...
-- `"scope"`)"; docs/02-semantics.md, "The `lifetime` table":
-- `lifetime.format` renders a scope as `scope`, and object anchors render
-- through `tostring`, so a formula that mentions a scope reads
-- `(scope, reachable)`.
local SCOPE_MT = {
    __metatable = "scope",
    __tostring = function()
        return "scope"
    end
}

-- docs/03-runtime.md, "Scope records": "The runtime's own field
-- `lifetime.scope` is ... a table with a private metatable whose
-- `__index`, `__newindex` and `__call` raise `attempt to index
-- lifetime.scope`, whose `__tostring` is `lifetime.scope`, and which
-- `attach` refuses with `attempt to anchor to lifetime.scope through a
-- variable`. It is never a scope record."
--
-- The marker carries a state record whose phase is `"marker"`. Every
-- path that anchors to an object or moves one already falls off its fast
-- path on a set phase, so the refusals below cost the common case
-- nothing, and the marker can never be given a state record of the
-- ordinary kind (and so become an anchor) by `of`, `destroy` or `@`.
local MARKER_MESSAGE = "attempt to anchor to lifetime.scope through a variable"
local MARKER_MT = {__metatable = "lifetime.scope"}
MARKER_MT.__index = function()
    error("attempt to index lifetime.scope", 2)
end
MARKER_MT.__newindex = MARKER_MT.__index
MARKER_MT.__call = MARKER_MT.__index
MARKER_MT.__tostring = function()
    return "lifetime.scope"
end
local MARKER = {}
MARKER[STATE] = {
    false,
    false,
    n = 0,
    reachable = true,
    deps = false,
    phase = "marker",
    phase_id = 0,
    name = false,
    where = false,
    reason = false
}
setmetatable(MARKER, MARKER_MT)
lifetime.scope = MARKER

-- The argument error for something `destroy`, `discard`, `lifetime.of`
-- and `lifetime.format` cannot take that is a runtime table but not an
-- object of the language: the marker, or a scope record reached through
-- a lifetime value ("`destroy` of a scope is impossible"). Error path
-- only; nil for everything else.
local function not_an_object(obj)
    local mt = debug_getmetatable(obj)
    if mt == MARKER_MT then
        return "lifetime.scope"
    elseif mt == SCOPE_MT then
        return "scope"
    end
    return nil
end

------------------------------------------------------------------------
-- Dependents lists
------------------------------------------------------------------------

-- docs/03-runtime.md, "The state of an object": an anchor's dependents
-- live in two tables that share one sequence counter: `deps`, weak-valued,
-- for every dependent whose formula carries the `reachable` term, and
-- `strong`, strong-valued, for hooks and pinned dependents ("A hook is
-- pinned by its anchor ... the anchor is what holds it";
-- docs/05-decisions.md, "Pinned dependents are held by their anchors").
-- A sequence number is in one of the two at most, and every walk merges
-- them by sequence number. The counters `seq`, `lo` and `limit` live in
-- `deps`, which every anchor has from its first link. `strong` is created
-- on the first pinned link; a plain record does not carry the field until
-- then (hooks and scope records do), so an anchor that never holds a hook
-- pays nothing for it.

-- docs/03-runtime.md, "The state of an object": "When holes outnumber
-- live entries the runtime compacts: it renumbers the live entries
-- densely from `lo`, in order, updates each dependent's stored sequence
-- number, and resets `seq`." Called from `link` only, never during a
-- destroy phase. Returns the next free sequence number.
local function compact(anchor, ast, deps)
    local strong = ast.strong
    local lo, seq = deps.lo, deps.seq
    local live = 0
    for i = lo, seq - 1 do
        if deps[i] ~= nil or (strong and strong[i] ~= nil) then
            live = live + 1
        end
    end
    if seq - lo - live > live then
        -- Every slot in `[to, from)` is empty in both tables when `from`
        -- is reached, so an entry moves down within its own table.
        local to = lo
        for from = lo, seq - 1 do
            local list = deps
            local dep = deps[from]
            if dep == nil and strong then
                list = strong
                dep = strong[from]
            end
            if dep ~= nil then
                if from ~= to then
                    list[to] = dep
                    list[from] = nil
                    local dst = rawget(dep, STATE)
                    for j = 1, 2 * dst.n, 2 do
                        if rawequal(dst[j], anchor) and dst[j + 1] == from then
                            dst[j + 1] = to
                            break
                        end
                    end
                end
                to = to + 1
            end
        end
        seq = to
        deps.seq = seq
    end
    -- Twice the range after the scan, so the next scan comes after as
    -- many links again as this one cost.
    local limit = 2 * (seq - lo)
    deps.limit = limit > MIN_LIMIT and limit or MIN_LIMIT
    return seq
end

-- Link `obj` at the end of `anchor`'s list; returns its sequence number
-- (docs/03-runtime.md, "Attachment", step 4). `pinned` (a hook, or a
-- formula without the `reachable` term) puts it in `strong`: "Hooks and
-- pinned dependents go into `strong` instead of `dependents` under the
-- same sequence counter".
--
-- An anchor's first link gives it dependents, so an anchor with the
-- `reachable` term needs a sentinel from now on (docs/03-runtime.md, "The
-- sentinel": "a table whose formula has the `reachable` term and that has
-- a `__destroy`, dependents or hooks"; "a token with the `reachable`
-- term", under the same rule). A scope record needs one only when it is
-- on a coroutine's stack: the main thread's stack is the runtime's own
-- root, so a record on it is never unreachable while active ("a scope
-- record, so that the records of a collected suspended coroutine are
-- destroyed"). Called inside a `busy` operation.
local function link(anchor, ast, obj, pinned)
    local deps = ast.deps
    if not deps then
        deps = spare_deps
        if deps then
            spare_deps = false
        else
            deps = setmetatable({seq = 1, lo = 1, limit = MIN_LIMIT}, WEAK_VALUES)
        end
        ast.deps = deps
        local term = ast.reachable
        if term == true then
            ast.reachable = new_sentinel(anchor)
        elseif term == nil and ast.stack ~= main_stack then
            ast.sentinel = new_sentinel(anchor)
        end
    end
    local s = deps.seq
    if s - deps.lo >= deps.limit and phase_depth == 0 then
        s = compact(anchor, ast, deps)
    end
    if pinned then
        local strong = ast.strong
        if not strong then
            strong = spare_strong
            if strong then
                spare_strong = false
            else
                strong = {}
            end
            ast.strong = strong
        end
        strong[s] = obj
    else
        deps[s] = obj
    end
    deps.seq = s + 1
    return s
end

-- Unlink the entry `s` from an anchor's list (docs/03-runtime.md,
-- "Attachment", step 3, and "The cascade", the tombstone step), whichever
-- of the two tables holds it: `strong` when `pinned`, which the caller
-- reads from the dependent's record (a dependent is in its anchors'
-- `strong` tables exactly when its formula has no `reachable` term,
-- `st.reachable == false`). The range shrinks when the entry was at
-- either end, so attach-then-destroy in either order leaves no holes to
-- compact; a list that empties starts again at 1. Neither renumbers
-- anything, so it is safe while a cascade walks this list: the walk's
-- bounds are fixed when it starts.
local function unlink(ast, s, pinned)
    local deps = ast.deps
    if not deps then
        return
    end
    -- `strong` is read only when needed: the entry is in it, or a shrink
    -- loop is about to walk a slot `deps` does not hold. A move between
    -- anchors without hooks reads nothing more than before `strong`
    -- existed (bench/README.md, `runtime/move`). It is read before a
    -- loop, never inside one, so its type is fixed while the loop runs
    -- (a local that changes type inside a loop makes LuaJIT abort the
    -- trace: "persistent type instability").
    if pinned then
        local strong = ast.strong
        if strong then
            strong[s] = nil
        end
    else
        deps[s] = nil
    end
    local lo, seq = deps.lo, deps.seq
    if s == seq - 1 then
        s = s - 1
        if s >= lo and deps[s] == nil then
            local strong = ast.strong
            while s >= lo and deps[s] == nil and not (strong and strong[s] ~= nil) do
                s = s - 1
            end
        end
        if s < lo then
            deps.lo, deps.seq = 1, 1
        else
            deps.seq = s + 1
        end
    elseif s == lo then
        s = s + 1
        if s < seq and deps[s] == nil then
            local strong = ast.strong
            while s < seq and deps[s] == nil and not (strong and strong[s] ~= nil) do
                s = s + 1
            end
        end
        deps.lo = s
    end
end

------------------------------------------------------------------------
-- destroyerror
------------------------------------------------------------------------

-- docs/02-semantics.md, "Errors in destructors and `destroyerror`": "The
-- default writes `destroyerror: <message>` and a traceback to `stderr`."
local function default_destroyerror(obj, err)
    io.stderr:write(debug_traceback("destroyerror: " .. tostring(err), 3), "\n")
end

-- "`destroyerror(obj, err)` is a global function, looked up raw in `_G`
-- at the moment an error is routed ... If the handler itself raises, or
-- the global is not callable, the runtime writes both errors to `stderr`
-- (the second as `destroyerror: error in destroyerror (<message>)`) and
-- continues." Without the global the default runs.
local function call_destroyerror(obj, err)
    local handler = rawget(_G, "destroyerror")
    if handler == nil then
        default_destroyerror(obj, err)
        return
    end
    local depth = stack.n
    local ok, err2 = pcall(handler, obj, err)
    if not ok then
        if stack.n > depth then
            unwind(stack, depth)
        end
        io.stderr:write("destroyerror: ", tostring(err), "\n", "destroyerror: error in destroyerror (", tostring(err2), ")\n")
    end
end

-- The error rule: the first error of the cascade is held and re-raised
-- after it; every later one goes to `destroyerror`.
local function route(obj, err)
    if not held then
        held, held_error = true, err
        return
    end
    call_destroyerror(obj, err)
end

------------------------------------------------------------------------
-- The cascade
------------------------------------------------------------------------

-- docs/02-semantics.md, "Cascading death", step 1, **Decide**: mark the
-- object dying, then every dependent not yet dying or dead, depth first.
-- The dying set is closed when this returns. An object whose metatable
-- has a `__tostring` gets its tombstone name now (docs/03-runtime.md,
-- "The state of an object": "`name`: `tostring(obj)` captured when the
-- object starts dying"), while every object of the cascade is alive.
--
-- The dependents are the merge of `deps` and `strong` by sequence number.
-- A hook or a token needs no capture: its name is fixed at creation
-- (`hook_name`, `token_name`).
local function decide(obj, st, id)
    st.phase = "dying"
    st.phase_id = id
    local mt = debug_getmetatable(obj)
    if mt ~= nil and mt ~= HOOK_MT and mt ~= TOKEN_MT and rawget(mt, "__tostring") ~= nil then
        local depth = stack.n
        local ok, name = pcall(tostring, obj)
        if ok then
            st.name = name
        elseif stack.n > depth then
            unwind(stack, depth)
        end
    end
    local deps = st.deps
    if deps then
        local strong = st.strong
        for i = deps.seq - 1, deps.lo, -1 do
            local dep = deps[i]
            if dep == nil and strong then
                dep = strong[i]
            end
            if dep ~= nil then
                local dst = rawget(dep, STATE)
                if not dst.phase then
                    decide(dep, dst, id)
                end
            end
        end
    end
end

-- A destructor body raised: the records it pushed and its error left on
-- the stack die first, then the error is routed (`route`).
local function body_failed(obj, err, depth)
    if stack.n > depth then
        unwind(stack, depth)
    end
    route(obj, err)
end

-- docs/02-semantics.md, "Cascading death", step 2, **Destroy**, for one
-- object: (1) its own body, with every dependent alive; (2) its
-- dependents, most recently attached first, each by this same rule,
-- skipping those already destroyed (or decided by another cascade);
-- (3) emptied and tombstoned. The dependents walked are those the same
-- cascade decided: `st.phase_id` holds that cascade's id until now.
local function destroy_object(obj, st, reason, where, skip_body)
    local id = st.phase_id
    -- Reached: a second path to this object (a cycle, or a `destroy` by
    -- hand from a body) skips it.
    st.phase_id = 0

    -- 2.1: `__destroy` read from the metatable at the moment of death
    -- (docs/02-semantics.md, "`__destroy` and reasons", rule 1), called
    -- as `__destroy(obj, reason)`, or a hook's function as `fn(reason)`
    -- ("Hooks: the `!@` operator": "The function is called as
    -- `fn(reason)`"), in protected mode to route its error. That
    -- protected call is a catch the runtime sees: records the body pushed
    -- and its error left on the stack are unwound before the error is
    -- routed ("Scopes: `lifetime.scope`": they die "before that call
    -- returns to its caller").
    local mt = debug_getmetatable(obj)
    local hook = mt == HOOK_MT
    if not skip_body then
        if hook then
            local depth = stack.n
            local ok, err = pcall(st.fn, reason)
            if not ok then
                body_failed(obj, err, depth)
            end
        else
            local body = mt ~= nil and rawget(mt, "__destroy")
            if body then
                local depth = stack.n
                local ok, err = pcall(body, obj, reason)
                if not ok then
                    body_failed(obj, err, depth)
                end
            end
        end
    end

    -- 2.2: the dependents and hooks, newest first: a numeric loop over
    -- the range, skipping holes (CLAUDE.md, "Technical decisions"), with
    -- `deps` and `strong` merged by sequence number, so a hook runs "in
    -- its place among the object's other dependents by attachment order"
    -- (docs/02-semantics.md, "Hooks: the `!@` operator"). The bounds are
    -- read once; nothing can be linked to a dying anchor, and unlinking
    -- only empties slots.
    local deps = st.deps
    local strong = false
    if deps then
        strong = st.strong
        for i = deps.seq - 1, deps.lo, -1 do
            local dep = deps[i]
            if dep == nil and strong then
                dep = strong[i]
            end
            if dep ~= nil then
                local dst = rawget(dep, STATE)
                if dst.phase_id == id and dst.phase == "dying" then
                    destroy_object(dep, dst, "anchor", where, false)
                end
            end
        end
    end

    -- 2.3: the tombstone (docs/03-runtime.md, "The tombstone"): unlink
    -- from the anchors' lists, clear every field, set the dead metatable,
    -- reduce the record to what the message needs.
    --
    -- One anchor, the common case, is unlinked without a loop. The fields
    -- are cleared by the `for` over `next` of task 002. A loop that runs
    -- once or twice per destruction becomes hot before a user's loop that
    -- destroys an object per iteration, and LuaJIT aborts the user's trace
    -- on it ("inner loop in root trace") during warm-up, until side traces
    -- cover it; the loop then runs compiled. A clear without a loop (a
    -- tail-recursive one) avoided those aborts but made `runtime/move`
    -- about 1.8 times as slow on LuaJIT after `runtime/attach-destroy-100`
    -- in the same process, whatever the load path (task file, "Spec
    -- issues found").
    local term = st.reachable
    local n, pinned = st.n, not term
    if n == 1 then
        unlink(rawget(st[1], STATE), st[2], pinned)
        st[1] = nil
        st[2] = nil
    else
        for j = 1, 2 * n, 2 do
            unlink(rawget(st[j], STATE), st[j + 1], pinned)
            st[j] = nil
            st[j + 1] = nil
        end
    end
    for k in next, obj do
        if k ~= STATE then
            obj[k] = nil
        end
    end
    debug_setmetatable(obj, DEAD_MT)
    st.n = 0
    -- Written only when set, so that a record without the field (a hook)
    -- does not grow at death. A dead anchor holds nothing strongly; a dead
    -- hook lets its function go ("After it runs the hook is dead: a hook
    -- runs at most once"). `strong` was read with `deps` (a table has
    -- `strong` only once it has `deps`).
    if deps then
        st.deps = false
        if strong then
            st.strong = false
        end
    end
    if hook then
        st.fn = false
    end
    -- The sentinel is disarmed: a dead object has nothing left to run at
    -- collection (docs/03-runtime.md, "The sentinel": the finalizer skips
    -- an object already dead).
    if term ~= true and term then
        drop_sentinel(term)
        st.reachable = true
    end
    st.phase = "dead"
    st.where = where
    st.reason = reason
end

-- `cascade(root, reason, where)` of docs/03-runtime.md, "The cascade":
-- decide, then destroy, then re-raise the held error. One call is one
-- destroy phase (docs/02-semantics.md, "No moves during destruction") and
-- one cascade for the error rule ("Errors in destructors": "a `destroy()`
-- inside a destructor is a cascade of its own and raises to that call").
-- A root already decided dying by a running cascade and not yet reached
-- (a destructor destroying its own dependent by hand, early) is
-- destroyed now with the subtree that cascade decided, which is closed.
--
-- `propagating` is the finalizer's: "the sentinel's finalizer runs the
-- cascade in protected mode and every error of it goes to
-- `destroyerror`, the first included" (docs/02-semantics.md, "Errors in
-- destructors and `destroyerror`"), so the cascade starts as if an error
-- were already propagating, and raises nothing.
local function cascade(root, st, reason, where, skip_body, propagating)
    local id = phase_counter + 1
    phase_counter = id
    if not st.phase then
        decide(root, st, id)
    end
    local outer_id, outer_held, outer_error = phase_id, held, held_error
    phase_id, phase_depth, held, held_error = id, phase_depth + 1, propagating or false, nil
    destroy_object(root, st, reason, where, skip_body)
    local raise, err = held and not propagating, held_error
    phase_id, phase_depth, held, held_error = outer_id, phase_depth - 1, outer_held, outer_error
    if raise then
        error(err, 0)
    end
end

-- `<where>`: "`chunk:line` of the `destroy` call" (docs/02-semantics.md,
-- "Tombstones"; docs/03-runtime.md, "The cascade": `debug.getinfo(2,
-- "Sl")`). Level 3 here: this function, `destroy`/`discard`, its caller.
local function where_of_caller()
    local info = debug_getinfo(3, "Sl")
    if not info then
        return "?"
    end
    if info.currentline and info.currentline > 0 then
        return info.short_src .. ":" .. info.currentline
    end
    return info.short_src
end

local function not_implemented(what)
    error("lifetime: " .. what .. " of a function, coroutine or userdata is not implemented yet (task 002 covers tables)", 3)
end

-- The state record of the object `destroy` or `discard` was given, or
-- `nil` when there is nothing to do (`nil`, dying, dead).
local function destroy_target(obj, fname)
    local t = type(obj)
    if t ~= "table" then
        if obj == nil then
            return nil
        end
        if t == "function" or t == "thread" or t == "userdata" then
            not_implemented(fname)
        end
        error("bad argument #1 to '" .. fname .. "' (object expected, got " .. t .. ")", 3)
    end
    local st = rawget(obj, STATE)
    if st then
        -- "`destroy` on a dead or dying object is a no-op, so a
        -- destructor body may destroy its own dependents by hand, early,
        -- and the runtime's later pass skips them": no-op once dead or
        -- once its destruction has begun (`phase_id` 0); a dependent
        -- decided dying and not yet reached is destroyed now. See the
        -- task file, "Spec issues found".
        local phase = st.phase
        if phase == "dead" or (phase == "dying" and st.phase_id == 0) then
            return nil
        end
        -- docs/02-semantics.md, "Scopes: `lifetime.scope`": "`destroy` of
        -- a scope is impossible"; the marker is not an object either.
        local what = (phase == "marker" or st.n == nil) and not_an_object(obj)
        if what then
            error("bad argument #1 to '" .. fname .. "' (object expected, got " .. what .. ")", 3)
        end
        return st
    end
    if is_value(obj) then
        error("bad argument #1 to '" .. fname .. "' (object expected, got lifetime)", 3)
    end
    return new_state(obj)
end

-- docs/02-semantics.md, "Explicit destruction: `destroy` and `discard`":
-- "`destroy(obj)` ends `obj`'s lifetime now, whatever its formula, with
-- the full cascade ... `destroy(nil)` is a no-op. `destroy` on a dead or
-- dying object is a no-op ... `destroy(5)` is `bad argument #1 to
-- 'destroy' (object expected, got number)`."
--
-- `where_of_caller` allocates, so the collector may run a finalizer
-- there ("Sentinels" above) whose cascade kills `obj`: the test is
-- repeated after it, and a `destroy` that comes second is a no-op.
function lifetime.destroy(obj)
    local st = destroy_target(obj, "destroy")
    if st then
        local where = where_of_caller()
        if st.phase ~= "dead" then
            cascade(obj, st, "destroy", where, false)
        end
    end
end

-- "`discard(obj)` does the same but skips `obj`'s own destructor".
function lifetime.discard(obj)
    local st = destroy_target(obj, "discard")
    if st then
        local where = where_of_caller()
        if st.phase ~= "dead" then
            cascade(obj, st, "destroy", where, true)
        end
    end
end

------------------------------------------------------------------------
-- Attachment
------------------------------------------------------------------------

-- docs/02-semantics.md, "Acquiring a lifetime", step 2, for one element:
-- a live table, or a lifetime value whose anchors are all live. Returns
-- whether the element carries the `reachable` term ("The implicit
-- `reachable` term": a table carries it; a value carries it if it does).
-- Raises at `level` (counted from this function). A dead or dying token
-- is named as one: "`attempt to anchor to a dead table` (or `dead
-- token`)" (docs/05-decisions.md, "Lifetime values are immutable
-- snapshots").
local function check_anchor(a, level)
    if type(a) ~= "table" then
        error("attempt to anchor to a " .. type(a) .. " value", level)
    end
    local ast = rawget(a, STATE)
    if ast then
        local phase = ast.phase
        if phase then
            if phase == "marker" then
                error(MARKER_MESSAGE, level)
            end
            error("attempt to anchor to a " .. phase .. (ast.token and " token" or " table"), level)
        end
        return true
    end
    if is_value(a) then
        -- "`@` on a value that mentions a dead anchor raises `attempt to
        -- anchor to a dead table`" (docs/05-decisions.md, "Lifetime
        -- values are immutable snapshots").
        for i = 1, a.n do
            local ast_i = rawget(a[i], STATE)
            local phase = ast_i and ast_i.phase
            if phase then
                error("attempt to anchor to a " .. phase .. (ast_i.token and " token" or " table"), level)
            end
        end
        return a.reachable
    end
    return true
end

-- Whether `obj` has a `__destroy`, for the sentinel (docs/03-runtime.md,
-- "The sentinel": "a table whose formula has the `reachable` term and
-- that has a `__destroy`"). `mt` is `getmetatable(obj)`, which LuaJIT
-- compiles: the real metatable unless it is protected. A `__destroy`
-- found there is the answer for an unprotected metatable, the common
-- case; otherwise `debug.getmetatable` decides (a protected metatable, or
-- a metatable without `__destroy`). `__destroy` is read again at the
-- moment of death; a `__destroy` added later than this check runs on
-- `destroy` and on an anchor's death, but not at collection ("allocated
-- lazily: on the first `@` that makes the object need one, not at
-- `setmetatable`").
local function has_destroy(obj, mt)
    if mt == nil then
        return false
    end
    if type(mt) == "table" and rawget(mt, "__destroy") ~= nil then
        return true
    end
    local real = debug_getmetatable(obj)
    if real == nil or rawequal(real, mt) then
        return false
    end
    return rawget(real, "__destroy") ~= nil
end

-- Link `obj` (record `st`) to the anchors of element `a`, from pair
-- index `k` on; returns the next pair index.
local function link_element(obj, st, a, k, pinned)
    if rawget(a, STATE) == nil and is_value(a) then
        for i = 1, a.n do
            local anchor = a[i]
            st[k] = anchor
            st[k + 1] = link(anchor, rawget(anchor, STATE) or new_state(anchor), obj, pinned)
            k = k + 2
        end
        return k
    end
    local ast = rawget(a, STATE) or new_state(a)
    st[k] = a
    st[k + 1] = link(a, ast, obj, pinned)
    return k + 2
end

-- The general path of `@` and `!@`: steps 1 to 4 of docs/02-semantics.md,
-- "Acquiring a lifetime", for any arguments. `fname` names the entry point
-- in the argument error; every error is raised at the level of the
-- entry point's caller, which calls this without a tail call.
local function attach_general(fname, obj, pin, count, ...)
    local t = type(obj)

    -- Step 1: an object.
    if t ~= "table" then
        if t == "function" or t == "thread" or t == "userdata" then
            error("lifetime: attach of a function, coroutine or userdata is not implemented yet (task 002 covers tables)", 3)
        end
        error("attempt to anchor a " .. t .. " value", 3)
    end

    -- Step 2: every element, left to right, before anything changes.
    local term = false
    if count == 1 then
        term = check_anchor((...), 4)
    else
        if count == 0 then
            error("bad argument #3 to '" .. fname .. "' (anchor expected, got no value)", 3)
        end
        for i = 1, count do
            if check_anchor((select(i, ...)), 4) then
                term = true
            end
        end
    end

    -- Step 3: the object itself.
    local st = rawget(obj, STATE)
    if st then
        local phase = st.phase
        if phase == "dying" then
            error("attempt to move a dying table", 3)
        elseif phase == "dead" then
            -- "If `e` is dead, the dead metatable raises first".
            error(dead_message(obj, st, "index"), 3)
        elseif phase == "marker" then
            -- docs/02-semantics.md, "Scopes: `lifetime.scope`": "`@` on
            -- it raises `attempt to anchor to lifetime.scope through a
            -- variable`".
            error(MARKER_MESSAGE, 3)
        elseif st.n == nil then
            -- A scope record, reached through a lifetime value: a scope
            -- is not an object that can be moved.
            error("attempt to anchor a scope value", 3)
        end
        -- docs/02-semantics.md, "No moves during destruction": only
        -- objects on the default formula or created during the innermost
        -- running destroy phase may be moved.
        if phase_depth > 0 and (st.n > 0 or not st.reachable) and st.phase_id ~= phase_id then
            error("attempt to move an anchored table during destruction", 3)
        end
        -- "A move keeps it pinned: `hook @ other` never adds the
        -- `reachable` term to a hook" (docs/02-semantics.md, "Hooks").
        if st.fn ~= nil then
            pin = true
        end
    elseif is_value(obj) then
        error("attempt to anchor a lifetime value", 3)
    end

    -- Everything is valid; from here on the collector's finalizers wait
    -- ("Sentinels": `busy`).
    busy = busy + 1
    if st == nil then
        st = new_state(obj)
    end

    -- Step 4: replace the formula; leave the old anchors' lists, join the
    -- new ones' at the end, in `strong` when the new formula has no
    -- `reachable` term.
    local reachable = term and not pin
    local old = 2 * st.n
    local had = st.reachable
    for j = 1, old, 2 do
        unlink(rawget(st[j], STATE), st[j + 1], not had)
    end
    local k = 1
    if count == 1 then
        k = link_element(obj, st, (...), k, not reachable)
    else
        for i = 1, count do
            k = link_element(obj, st, (select(i, ...)), k, not reachable)
        end
    end
    for j = k, old do
        st[j] = nil
    end
    local n = (k - 1) / 2
    st.n = n

    -- The sentinel, after the anchors got theirs, so that it is the newest
    -- (docs/03-runtime.md, "The sentinel"). A hook whose formula is the
    -- term alone (`f !@ lifetime.reachable`) carries one and runs when
    -- collected (docs/05-decisions.md, "A hook anchored to
    -- `lifetime.reachable` alone runs when collected"); every other hook
    -- and every pinned object carries none. A move that keeps the term
    -- keeps the sentinel; one that drops the term drops it.
    local hook = st.fn ~= nil
    if hook and n == 0 then
        reachable = true
    end
    if reachable then
        if had == true or had == false then
            if hook or st.deps or has_destroy(obj, getmetatable(obj)) then
                st.reachable = new_sentinel(obj)
            else
                st.reachable = true
            end
        end
    else
        if had ~= true and had then
            drop_sentinel(had)
        end
        st.reachable = false
    end
    busy = busy - 1
    if busy == 0 and queue_tail ~= 0 then
        drain()
    end
    return obj
end

-- docs/03-runtime.md, "Attachment: what `@` does": `lifetime.attach(obj,
-- pin, a1, …, an)` performs steps 1 to 4 of docs/02-semantics.md,
-- "Acquiring a lifetime", and returns `obj`. `pin` true attaches without
-- the implicit `reachable` term (hooks); otherwise the formula carries it
-- when any element does ("The implicit `reachable` term"), so a list of
-- `lifetime.pin` values alone is pinned. A formula without the term is
-- pinned: the anchors hold the object in their `strong` tables. A hook
-- stays pinned whatever `pin` says, unless its formula is the term
-- alone. Step 5, the sentinel, follows docs/03-runtime.md, "The
-- sentinel".
function lifetime.attach(obj, pin, ...)
    local count = select("#", ...)

    -- The common case, without a call: one anchor, a live table the
    -- runtime has seen, and an object that is new to the runtime, or
    -- alive with one anchor and the `reachable` term and staying so (the
    -- ordinary move; a pinned object or a hook takes the general path),
    -- outside any destroy phase. It does exactly what the general path
    -- does for these arguments; anything else falls through to it. A move
    -- keeps the object's sentinel, if it has one; only the anchor may need
    -- one (`link`).
    if count == 1 and type(obj) == "table" and phase_depth == 0 then
        local a = ...
        local ast = type(a) == "table" and rawget(a, STATE)
        if ast and not ast.phase then
            local st = rawget(obj, STATE)
            if st == nil then
                local mt = getmetatable(obj)
                if mt ~= "lifetime" then
                    busy = busy + 1
                    st = new_state(obj)
                    st[1] = a
                    st[2] = link(a, ast, obj, pin)
                    st.n = 1
                    if pin then
                        st.reachable = false
                    elseif has_destroy(obj, mt) then
                        st.reachable = new_sentinel(obj)
                    end
                    busy = busy - 1
                    if busy == 0 and queue_tail ~= 0 then
                        drain()
                    end
                    return obj
                end
            elseif not st.phase and st.n == 1 and st.reachable and not pin then
                busy = busy + 1
                unlink(rawget(st[1], STATE), st[2], false)
                st[1] = a
                st[2] = link(a, ast, obj, false)
                busy = busy - 1
                if busy == 0 and queue_tail ~= 0 then
                    drain()
                end
                return obj
            end
        end
    end

    local result = attach_general("lifetime.attach", obj, pin, count, ...)
    return result
end

------------------------------------------------------------------------
-- Inspection
------------------------------------------------------------------------

-- The record's `reachable` may hold the sentinel; a value holds the term
-- as a boolean and never the sentinel.
local function value_of(st)
    local n = st.n
    local term = st.reachable ~= false
    if n == 0 and term then
        return REACHABLE
    end
    local v = new_value(n, term)
    for i = 1, n do
        v[i] = st[2 * i - 1]
    end
    return v
end

-- docs/02-semantics.md, "The `lifetime` table": "`lifetime.of(obj)`:
-- `obj`'s current formula as a lifetime value, a snapshot ... Error on
-- `nil`, a value, a dead object." Passing an object to `of` makes the
-- runtime see it ("`__destroy` and reasons", rule 7); on the default
-- lifetime it returns `lifetime.reachable`. Seen with the term and a
-- `__destroy`, the object gets its sentinel now, so that the collector
-- finds it (rule 7: the runtime can notify the objects it has seen).
function lifetime.of(obj)
    local t = type(obj)
    if t ~= "table" then
        if t == "function" or t == "thread" or t == "userdata" then
            not_implemented("lifetime.of")
        end
        error("bad argument #1 to 'lifetime.of' (object expected, got " .. t .. ")", 2)
    end
    local st = rawget(obj, STATE)
    if st then
        local phase = st.phase
        if phase == "dead" then
            error(dead_message(obj, st, "index"), 2)
        end
        local what = (phase == "marker" or st.n == nil) and not_an_object(obj)
        if what then
            error("bad argument #1 to 'lifetime.of' (object expected, got " .. what .. ")", 2)
        end
        return value_of(st)
    end
    if is_value(obj) then
        error("bad argument #1 to 'lifetime.of' (object expected, got lifetime)", 2)
    end
    st = new_state(obj)
    if has_destroy(obj, getmetatable(obj)) then
        st.reachable = new_sentinel(obj)
    end
    return REACHABLE
end

-- "`lifetime.dependents(obj)`: A fresh array of the live objects and
-- hooks whose formula mentions `obj`, in attachment order." Oldest first:
-- the same numeric loop as the cascade, the other way, over `deps` and
-- `strong` merged by sequence number. Does not make the runtime see
-- `obj`.
function lifetime.dependents(obj)
    local t = type(obj)
    if t ~= "table" and t ~= "function" and t ~= "thread" and t ~= "userdata" then
        error("bad argument #1 to 'lifetime.dependents' (object expected, got " .. t .. ")", 2)
    end
    local result = {}
    local st = t == "table" and rawget(obj, STATE)
    local deps = st and st.deps
    if deps then
        local strong = st.strong
        local n = 0
        if strong then
            for i = deps.lo, deps.seq - 1 do
                local dep = deps[i]
                if dep == nil then
                    dep = strong[i]
                end
                if dep ~= nil then
                    n = n + 1
                    result[n] = dep
                end
            end
        else
            -- No hook and no pinned dependent: `deps` alone, one test less
            -- per entry (bench/README.md, `runtime/dependents-100`).
            for i = deps.lo, deps.seq - 1 do
                local dep = deps[i]
                if dep ~= nil then
                    n = n + 1
                    result[n] = dep
                end
            end
        end
    end
    return result
end

-- `(a, reachable)`, `a`, `(a, b)`, `reachable`: the anchors through
-- `tostring`, then the term; parentheses around more than one item.
local function format_items(items, n, reachable)
    if reachable then
        n = n + 1
        items[n] = "reachable"
    end
    if n == 1 then
        return items[1]
    end
    return "(" .. concat(items, ", ", 1, n) .. ")"
end

-- docs/02-semantics.md, "The `lifetime` table": "`lifetime.format(v)`: A
-- string rendering of a lifetime value, an object's formula ... Object
-- anchors render through `tostring`, so a dead anchor in a snapshot
-- renders as `dead <name>`." A hook renders as itself: "`hook cleanup`
-- for a named hook and `hook` for an anonymous one"; a scope record as
-- `scope`; a token as `token period` ("Tokens": "`lifetime.format` and
-- the tombstone's message use the same text" as `tostring`).
function lifetime.format(v)
    if type(v) ~= "table" then
        error("bad argument #1 to 'lifetime.format' (lifetime expected, got " .. type(v) .. ")", 2)
    end
    local mt = debug_getmetatable(v)
    if mt == HOOK_MT then
        local name = rawget(v, STATE).name
        return name and "hook " .. tostring(name) or "hook"
    elseif mt == TOKEN_MT then
        return token_name(v, rawget(v, STATE))
    elseif mt == SCOPE_MT then
        return "scope"
    elseif mt == MARKER_MT then
        error("bad argument #1 to 'lifetime.format' (lifetime expected, got lifetime.scope)", 2)
    end
    local items = {}
    if is_value(v) then
        for i = 1, v.n do
            items[i] = tostring(v[i])
        end
        return format_items(items, v.n, v.reachable)
    end
    local st = rawget(v, STATE)
    if not st then
        return "reachable"
    end
    if st.phase == "dead" then
        error(dead_message(v, st, "index"), 2)
    end
    local n = st.n
    for i = 1, n do
        items[i] = tostring(st[2 * i - 1])
    end
    return format_items(items, n, st.reachable)
end

------------------------------------------------------------------------
-- Hooks
------------------------------------------------------------------------

-- docs/03-runtime.md, "Hooks": "`lifetime.hook(f, name, a1, …)` creates a
-- hook: a table with a state record, the metatable `"hook"`, the
-- function, and the name (a constant string the emitter passes for a
-- named hook, `nil` otherwise). It is attached pinned to its anchors and
-- linked into each anchor's `strong` list, never into `dependents`, so
-- the anchor holds it strongly; it never carries a sentinel. Its body
-- calls `f(reason)`." Except, since docs/05-decisions.md, "A hook
-- anchored to `lifetime.reachable` alone runs when collected": a hook
-- whose formula is the term alone carries one (`attach_general`).
--
-- The hook's record is an ordinary state record plus `fn`, with `name`
-- holding the name it was created with, and without `deps` (a hook is
-- rarely an anchor; `link` adds the field if it becomes one), so that its
-- hash part keeps eight slots. docs/02-semantics.md, "Hooks: the `!@`
-- operator": "The left operand must be a function: `attempt to defer a
-- number value`. A hook is not a function, so `h !@ x` on a hook is
-- `attempt to defer a hook value`".
function lifetime.hook(f, name, ...)
    if type(f) ~= "function" then
        local what = type(f)
        if what == "table" then
            local mt = getmetatable(f)
            if mt == "hook" or mt == "token" then
                what = mt
            end
        end
        error("attempt to defer a " .. what .. " value", 2)
    end
    local h = {}
    local st = {
        false,
        false,
        n = 0,
        reachable = false,
        phase = false,
        phase_id = phase_id,
        name = name or false,
        where = false,
        reason = false,
        fn = f
    }
    h[STATE] = st
    setmetatable(h, HOOK_MT)

    -- The common case, as in `attach`: one live anchor the runtime has
    -- seen (a scope record always is). A new object may be anchored
    -- during a destroy phase, so no phase test is needed here.
    local count = select("#", ...)
    if count == 1 then
        local a = ...
        local ast = type(a) == "table" and rawget(a, STATE)
        if ast and not ast.phase then
            busy = busy + 1
            st[1] = a
            st[2] = link(a, ast, h, true)
            st.n = 1
            busy = busy - 1
            if busy == 0 and queue_tail ~= 0 then
                drain()
            end
            return h
        end
    end
    local result = attach_general("lifetime.hook", h, true, count, ...)
    return result
end

------------------------------------------------------------------------
-- Tokens, pin, alive
------------------------------------------------------------------------

-- docs/02-semantics.md, "Tokens: `lifetime.token`": "`lifetime.token([name])`
-- returns a fresh one, on the default lifetime like any new object ... A
-- name that is not a string is `bad argument #1 to 'lifetime.token'
-- (string expected, got number)`." docs/03-runtime.md, "Tokens": "a table
-- with a state record, the metatable `"token"`, and the name (or `nil`)
-- for `tostring` and `lifetime.format`. It starts on the default
-- lifetime; ... it gets a sentinel under the same rule as a table": a
-- token has no `__destroy`, so it gets one with its first dependent or
-- hook (`link`), or when anchored with the term while it has some.
function lifetime.token(name)
    if name ~= nil and type(name) ~= "string" then
        error("bad argument #1 to 'lifetime.token' (string expected, got " .. type(name) .. ")", 2)
    end
    local t = {}
    t[STATE] = {
        false,
        false,
        n = 0,
        reachable = true,
        deps = false,
        phase = false,
        phase_id = phase_id,
        name = name or false,
        where = false,
        reason = false,
        token = true
    }
    return setmetatable(t, TOKEN_MT)
end

-- docs/02-semantics.md, "The implicit `reachable` term and
-- `lifetime.pin`": "`lifetime.pin(a1, …, an)` returns a lifetime value
-- over the listed anchors **without** the term ... `lifetime.pin` strips
-- the term from its arguments. `lifetime.pin()` with no arguments, and
-- `lifetime.pin` of nothing but `lifetime.reachable`, are errors (`bad
-- argument #1 to 'lifetime.pin' (anchor expected, got no value)` and
-- `attempt to pin an empty lifetime`)". Each argument is checked as an
-- element after `@` is ("Acquiring a lifetime", step 2), and a lifetime
-- value is spliced: its anchors, without its term. The value is a
-- snapshot like any other ("The `lifetime` table").
function lifetime.pin(...)
    local count = select("#", ...)
    if count == 0 then
        error("bad argument #1 to 'lifetime.pin' (anchor expected, got no value)", 2)
    end
    for i = 1, count do
        check_anchor((select(i, ...)), 3)
    end
    local v = new_value(0, false)
    local n = 0
    for i = 1, count do
        local a = select(i, ...)
        if rawget(a, STATE) == nil and is_value(a) then
            for j = 1, a.n do
                n = n + 1
                v[n] = a[j]
            end
        else
            n = n + 1
            v[n] = a
        end
    end
    if n == 0 then
        error("attempt to pin an empty lifetime", 2)
    end
    v.n = n
    return v
end

-- docs/02-semantics.md, "Tombstones and `lifetime.alive`": "`true` for an
-- object that is alive or dying, `false` for a tombstone and for `nil` or
-- `false`; a value that is not an object is `bad argument #1 to
-- 'lifetime.alive' (object expected, got number)`." A function,
-- coroutine or userdata is alive: the runtime cannot destroy one yet
-- (docs/06-open-questions.md, "Non-table dependents after death"; task
-- 012).
function lifetime.alive(x)
    if type(x) == "table" then
        local st = rawget(x, STATE)
        return not st or st.phase ~= "dead"
    end
    if not x then
        return false
    end
    local t = type(x)
    if t == "function" or t == "thread" or t == "userdata" then
        return true
    end
    error("bad argument #1 to 'lifetime.alive' (object expected, got " .. t .. ")", 2)
end

------------------------------------------------------------------------
-- Scope records
------------------------------------------------------------------------

-- docs/03-runtime.md, "Scope records": "A scope record is a runtime table
-- the generated block prologue creates (`lifetime.enter()`) and the
-- epilogue destroys (`lifetime.exit(record, line)`): a cascade with the
-- record as root, no body, reason `"anchor"` for its dependents."
--
-- A record is one table and is its own state record (`rec[STATE] ==
-- rec`), so `enter` allocates nothing else (docs/03-runtime.md,
-- "Performance": "one record (a small table) per entry"). It has the
-- fields an anchor needs (`deps`, `strong`, `phase`) and those of the
-- scope stack: `line`, the position of the block's `end` for the
-- tombstones of an unwound record; `depth`, its index in the stack; and
-- `stack`, the stack it is on. A record is never a dependent: it has no
-- formula and no `n`.
--
-- `stack` is what keeps a suspended coroutine's stack alive. The table
-- that finds a coroutine's stack (`stacks`, below) is weak in its values
-- as well as its keys, so that the stack, and the hooks its records hold
-- in `strong`, can never keep the coroutine itself alive: in Lua 5.1 a
-- weak-keyed table marks its values strongly, and a hook that refers to
-- its own coroutine would otherwise make it uncollectable. The records
-- are held by the coroutine's frames (the generated locals), and they
-- hold the stack, so the stack lives exactly while the coroutine has an
-- active record or is running.
--
-- The line arguments are the positions the tombstones report
-- (docs/02-semantics.md, "Tombstones": "`<where>` is the source position
-- of the statement that caused the cascade"). The runtime stores them as
-- given and renders them with `tostring`; the generated code passes the
-- constant `"chunk:line"`, so no `debug.*` runs per block (CLAUDE.md,
-- "Technical decisions"; the task file, "Spec issues found").

-- docs/02-semantics.md, "Cascading death": "A scope has no body: scope
-- exit destroys the objects anchored to it in reverse attachment order".
-- The decide and destroy steps of `cascade` with the record as the root,
-- reason `"anchor"` for every dependent. One scope exit with dependents
-- is one destroy phase ("No moves during destruction"). The error rule is
-- the caller's: `held` is set up by `exit` (the first error is raised at
-- the exit) or by `unwind` (an error is propagating, so every error goes
-- to `destroyerror`).
--
-- A record with one entry, the most common block, is walked without a
-- loop, for the reason given at the tombstone step of `destroy_object`.
local function decide_entry(deps, strong, i, id)
    local dep = deps[i]
    if dep == nil and strong then
        dep = strong[i]
    end
    if dep ~= nil then
        local dst = rawget(dep, STATE)
        if not dst.phase then
            decide(dep, dst, id)
        end
    end
end

local function destroy_entry(deps, strong, i, id, where)
    local dep = deps[i]
    if dep == nil and strong then
        dep = strong[i]
    end
    if dep ~= nil then
        local dst = rawget(dep, STATE)
        if dst.phase_id == id and dst.phase == "dying" then
            destroy_object(dep, dst, "anchor", where, false)
        end
    end
end

local function scope_cascade(rec, where)
    rec.phase = "dying"
    local deps = rec.deps
    if deps then
        local strong = rec.strong
        local id = phase_counter + 1
        phase_counter = id
        local hi, lo = deps.seq - 1, deps.lo
        local outer_id = phase_id
        if hi == lo then
            decide_entry(deps, strong, hi, id)
            phase_id, phase_depth = id, phase_depth + 1
            destroy_entry(deps, strong, hi, id, where)
        else
            for i = hi, lo, -1 do
                decide_entry(deps, strong, i, id)
            end
            phase_id, phase_depth = id, phase_depth + 1
            for i = hi, lo, -1 do
                destroy_entry(deps, strong, i, id, where)
            end
        end
        phase_id, phase_depth = outer_id, phase_depth - 1
        -- Every dependent unlinked itself when it was tombstoned; a list
        -- that is empty again (`seq` back at 1, which `unlink` guarantees
        -- for both tables) is kept for the next first link. A dependent
        -- this exit skipped (decided by another running cascade) or a
        -- hole a collected dependent left keeps it from being reused.
        if deps.seq == 1 then
            deps.limit = MIN_LIMIT
            spare_deps = deps
            if strong then
                spare_strong = strong
            end
        end
        rec.deps = false
        rec.strong = false
        -- Only a record on a coroutine's stack that got dependents has a
        -- sentinel (`link`); the main thread's records never read more
        -- than this missing field.
        local p = rec.sentinel
        if p then
            rec.sentinel = false
            drop_sentinel(p)
        end
    end
    rec.phase = "dead"
end

-- docs/03-runtime.md, "The scope stack and the error path": "The block
-- prologue `lifetime.enter(line)` creates the record, stores `line` (the
-- line of the block's `end`, for the tombstones of an unwound record) and
-- its depth, and pushes it". No `debug.*`, no `coroutine.running`, no
-- `select`, no closure (CLAUDE.md, "Technical decisions").
function lifetime.enter(line)
    local s = stack
    local n = s.n + 1
    local rec = {deps = false, strong = false, phase = false, line = line, depth = n, stack = s}
    rec[STATE] = rec
    setmetatable(rec, SCOPE_MT)
    s[n] = rec
    s.n = n
    return rec
end

-- docs/02-semantics.md, "Scopes: `lifetime.scope`": "A record that a
-- catch the runtime could not see left behind dies at the next scope exit
-- of the same coroutine that finds it above itself, innermost first";
-- docs/03-runtime.md: "If `exit` finds records above `record` on the
-- stack, a catch the runtime could not see left them behind: it unwinds
-- them first, innermost first, then proceeds." The records left behind
-- die as their blocks' ends would have destroyed them (their own `line`).
-- The whole exit is one statement for the error rule: the first error of
-- all of it is raised after the last record is done.
local function exit_unwinding(s, rec, line)
    local outer_held, outer_error = held, held_error
    held, held_error = false, nil
    local depth = rec.depth
    if s[depth] == rec then
        while s.n > depth do
            local n = s.n
            local left = s[n]
            s[n] = nil
            s.n = n - 1
            scope_cascade(left, left.line)
        end
        s[depth] = nil
        s.n = depth - 1
        scope_cascade(rec, line)
    elseif not rec.phase then
        -- Not on the running coroutine's stack (a stack a hidden resume
        -- did not swap): its dependents still die at this exit.
        scope_cascade(rec, line)
    end
    local raise, err = held, held_error
    held, held_error = outer_held, outer_error
    if raise then
        error(err, 0)
    end
end

-- docs/03-runtime.md, "The scope stack and the error path": "the
-- epilogue `lifetime.exit(record, line)` pops it and runs the cascade".
-- The record is popped before its dependents die, so a destructor that
-- enters and exits blocks of its own sees a consistent stack. The first
-- destructor error is raised here, at the block exit, after the whole
-- cascade (docs/02-semantics.md, "Errors in destructors": it "propagates
-- to the statement that caused the death: ... the block exit"). A record
-- nothing was ever attached to has no `deps` and needs no cascade: nothing
-- else can name it. `rec.deps` is read before the pop, so that a call
-- with no record on an empty stack (`s[0] == nil`) raises before it
-- changes anything (task 003, review finding F1).
function lifetime.exit(rec, line)
    local s = stack
    local n = s.n
    if s[n] ~= rec then
        return exit_unwinding(s, rec, line)
    end
    local deps = rec.deps
    s[n] = nil
    s.n = n - 1
    if deps then
        local outer_held, outer_error = held, held_error
        held, held_error = false, nil
        scope_cascade(rec, line)
        local raise, err = held, held_error
        held, held_error = outer_held, outer_error
        if raise then
            error(err, 0)
        end
    end
end

-- The error path: every record of `s` above `depth` dies, innermost
-- first, each popped before its cascade. An error is propagating, so
-- every destructor error goes to `destroyerror` and the original error
-- continues (docs/02-semantics.md, "Errors in destructors": "Every error
-- raised while an error is already propagating (... or any destructor
-- running because a scope is unwinding) goes to `destroyerror`"). The
-- `<where>` of the dependents is the line of the block's `end` given to
-- `enter`.
unwind = function(s, depth)
    local outer_held, outer_error = held, held_error
    held = true
    while s.n > depth do
        local n = s.n
        local rec = s[n]
        s[n] = nil
        s.n = n - 1
        scope_cascade(rec, rec.line)
    end
    held, held_error = outer_held, outer_error
end

------------------------------------------------------------------------
-- The finalizer
------------------------------------------------------------------------

-- docs/03-runtime.md, "Program end": "`lifetime run` sets an exit flag
-- after the main chunk has returned and its scope epilogue has run; from
-- then on the sentinel finalizers that the closing state runs report
-- `"exit"`." Task 007's `lifetime run` sets it; how an embedding host
-- sets it is open (docs/06-open-questions.md, "How an embedding host
-- announces program end"), so the name is the runtime's own for now.
local exiting = false

function lifetime.set_exiting(flag)
    exiting = flag and true or false
end

-- docs/02-semantics.md, "Coroutines": "A coroutine the collector finds
-- unreachable cannot run its pending epilogues ...: the runtime destroys
-- its scope records from the finalizer, innermost first". The record dies
-- with every record above it on its stack, innermost first, whichever
-- record's sentinel the collector runs first (a record without
-- dependents has none), so the order does not depend on the order in
-- which the records got their sentinels. Every destructor error goes to
-- `destroyerror` ("Errors in destructors": the finalizer's rule); the
-- dependents die with reason `"anchor"` at `collector`.
local function collect_record(rec)
    local outer_held, outer_error = held, held_error
    held = true
    local s, depth = rec.stack, rec.depth
    if s[depth] == rec then
        while s.n >= depth do
            local n = s.n
            local top = s[n]
            s[n] = nil
            s.n = n - 1
            scope_cascade(top, "collector")
        end
    else
        scope_cascade(rec, "collector")
    end
    held, held_error = outer_held, outer_error
end

-- docs/03-runtime.md, "The sentinel": "The finalizer runs `cascade(obj,
-- "unreachable", "collector")` in protected mode, routing every error of
-- the cascade to `destroyerror` ..., if the object is still
-- `"dying"`-eligible (not already dead through an earlier walk of the
-- same collection ...), with the exit flag of "Program end" turning the
-- reason into `"exit"`." An object that a running cascade has decided
-- dying is skipped too: that cascade destroys it. The spent sentinel is
-- taken off its owner first, so a later `@` that needs one makes a new
-- one.
local function run_finalizer(p)
    local mt = getmetatable(p)
    local owner = mt.owner
    if owner == nil then
        return
    end
    mt.owner = nil
    local st = rawget(owner, STATE)
    if st == owner then
        if owner.sentinel == p then
            owner.sentinel = false
        end
        if not owner.phase then
            local depth = stack.n
            local ok, err = pcall(collect_record, owner)
            if not ok then
                if stack.n > depth then
                    unwind(stack, depth)
                end
                call_destroyerror(owner, err)
            end
        end
        return
    end
    if st.reachable == p then
        st.reachable = true
    end
    if st.phase then
        return
    end
    local depth = stack.n
    local ok, err = pcall(cascade, owner, st, exiting and "exit" or "unreachable", "collector", false, true)
    if not ok then
        if stack.n > depth then
            unwind(stack, depth)
        end
        call_destroyerror(owner, err)
    end
end

-- The sentinels the collector finalized while the runtime was `busy`, in
-- the collector's order.
drain = function()
    while queue_head <= queue_tail do
        local p = queue[queue_head]
        queue[queue_head] = nil
        queue_head = queue_head + 1
        run_finalizer(p)
    end
    queue_head, queue_tail = 1, 0
end

finalize = function(p)
    if busy > 0 then
        queue_tail = queue_tail + 1
        queue[queue_tail] = p
        return
    end
    run_finalizer(p)
end

------------------------------------------------------------------------
-- The error path: pcall, xpcall, coroutine.resume, coroutine.wrap
------------------------------------------------------------------------

-- docs/03-runtime.md, "The scope stack and the error path": "When it is
-- first required the runtime replaces four globals, keeping the
-- originals as upvalues"; docs/05-decisions.md, "Scopes unwind at the
-- catch site, not in a per-block `pcall` wrapper".
--
-- The originals keep their own names as upvalues (`pcall` is the local of
-- the file's first line), so that an argument error they raise names
-- them as a direct call would on Lua 5.1, where the name comes from the
-- call site. The wrappers pass varargs through and allocate nothing ("a
-- `pcall` costs one field read before and one compare after").
local xpcall = xpcall
local create, resume, status = coroutine.create, coroutine.resume, coroutine.status

-- After a protected call: on an error, unwind what was pushed since the
-- call began, then return exactly what the original returned.
local function caught(depth, ok, ...)
    if ok then
        return ok, ...
    end
    if stack.n > depth then
        unwind(stack, depth)
    end
    return ok, ...
end

-- "`pcall` and `xpcall` read `S.stack.n` before the call and, when the
-- call returns `false`, unwind every record above that depth, innermost
-- first ... then return what the original returned." An `xpcall` message
-- handler runs at the raise point, before any record is unwound, as in
-- Lua (docs/02-semantics.md, "Scopes: `lifetime.scope`").
local function lifetime_pcall(...)
    local depth = stack.n
    return caught(depth, pcall(...))
end

local function lifetime_xpcall(...)
    local depth = stack.n
    return caught(depth, xpcall(...))
end

-- The stack of each coroutine resumed through the runtime, "created on
-- first resume, held in a weak-keyed table by coroutine"; weak-valued
-- too, see "Scope records" above.
local stacks = setmetatable({}, {__mode = "kv"})

-- After a resume: restore the resumer's stack, then, if the coroutine
-- died of an error, unwind its whole stack in the resumer's context. A
-- `false` from `resume` on a coroutine that is not dead (running or
-- normal) is a refusal to resume, and its stack is left alone.
local function resumed(co, saved, ok, ...)
    local s = stack
    stack = saved
    if not ok and s.n > 0 and status(co) == "dead" then
        unwind(s, 0)
    end
    return ok, ...
end

-- "`coroutine.resume` swaps `S.stack` to the target coroutine's stack
-- ... for the duration of the call and restores it after, which covers
-- the yield path without wrapping `coroutine.yield`; when the original
-- returns `false` the coroutine is dead and its whole stack is unwound."
--
-- The lookup comes first: reading `stacks[co]` is legal for any `co`, and
-- a coroutine resumed before has its stack there, so the common resume
-- pays no `type` call. Anything else is passed to the original, which
-- raises its own argument error.
local function lifetime_resume(co, ...)
    local s = stacks[co]
    if s == nil then
        if type(co) ~= "thread" then
            return resume(co, ...)
        end
        s = {n = 0}
        stacks[co] = s
    end
    local saved = stack
    stack = s
    return resumed(co, saved, resume(co, ...))
end

-- How `coroutine.wrap` re-raises, found once by asking the original
-- (docs/03-runtime.md: the function "re-raises as Lua's does"). Both
-- hosts prefix a string error with the position of the wrap function's
-- caller; Lua 5.1 also turns a number into such a string, LuaJIT passes
-- it on as it is. `error(e, level)` adds that prefix; the level that
-- reaches the caller from a function entered by a tail call is 3 on Lua
-- 5.1, which counts the tail call as a level, and 2 on LuaJIT.
local WRAP_PREFIXES_NUMBERS, TAIL_CALLER_LEVEL
do
    local _, number_error = pcall(coroutine.wrap(function()
        error(5, 0)
    end))
    WRAP_PREFIXES_NUMBERS = type(number_error) == "string"
    local function raise_at_caller()
        error("probe", 2)
    end
    local function tail_call()
        return raise_at_caller()
    end
    local _, probe = pcall(function()
        tail_call()
    end)
    TAIL_CALLER_LEVEL = probe == "probe" and 3 or 2
end

-- After a resume through a wrap function: as `resumed`, then return the
-- values or re-raise the error as the original would. Entered by a tail
-- call from the wrap function.
local function wrapped(co, saved, ok, ...)
    local s = stack
    stack = saved
    if ok then
        return ...
    end
    if s.n > 0 and status(co) == "dead" then
        unwind(s, 0)
    end
    local err = ...
    local t = type(err)
    if t == "string" or (t == "number" and WRAP_PREFIXES_NUMBERS) then
        error(err, TAIL_CALLER_LEVEL)
    end
    error(err, 0)
end

-- "`coroutine.wrap` creates through the original and returns a function
-- that resumes the same way and re-raises as Lua's does." The coroutine's
-- stack is the one `coroutine.resume` would find for it.
local function lifetime_wrap(f)
    local co = create(f)
    return function(...)
        local s = stacks[co]
        if s == nil then
            s = {n = 0}
            stacks[co] = s
        end
        local saved = stack
        stack = s
        return wrapped(co, saved, resume(co, ...))
    end
end

-- "`coroutine.running`, `coroutine.status`, `coroutine.create`,
-- `coroutine.yield` and `error` are untouched."
rawset(_G, "pcall", lifetime_pcall)
rawset(_G, "xpcall", lifetime_xpcall)
rawset(coroutine, "resume", lifetime_resume)
rawset(coroutine, "wrap", lifetime_wrap)

return lifetime
