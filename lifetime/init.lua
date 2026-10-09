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
-- (`of`, `reachable`, `format`), `dependents`, `is_state`. Task 003 adds
-- scope records and hooks; task 004 tokens, `pin`, `alive` and the
-- sentinel.
--
-- Rules this file keeps (CLAUDE.md, "Technical decisions"; rule 6):
--
-- * State lives inside the object, under the private key STATE. There is
--   no side table keyed by an object.
-- * An anchor's `deps` table is weak-valued: the runtime never keeps a
--   dependent alive. A dependent's record holds its anchors strongly.
-- * Dependents are walked by a numeric loop over the sequence range
--   `seq - 1 .. lo`, newest first, skipping holes; never `ipairs`, never
--   a sort. Holes are compacted on `link`, amortised, never during a
--   destroy phase.
-- * Nothing here keeps a strong reference to a user object except a
--   dependent's record (its anchors) and lifetime values (their anchors),
--   both of which the spec makes strong.

local lifetime = {}

local type, next, rawget, rawset, rawequal, select, tostring, pcall, error = type, next, rawget, rawset, rawequal, select, tostring, pcall, error
local getmetatable, setmetatable = getmetatable, setmetatable
local debug_getmetatable, debug_setmetatable, debug_getinfo, debug_traceback = debug.getmetatable, debug.setmetatable, debug.getinfo, debug.traceback
local concat = table.concat

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

------------------------------------------------------------------------
-- State records
------------------------------------------------------------------------

-- docs/03-runtime.md, "The state of an object". The record's fields are
-- fixed, so LuaJIT keeps one table shape; `false` stands for the
-- design's `nil`. The formula is `n` anchors in the array part as pairs
-- `[2i - 1] = anchor, [2i] = the sequence number under which this object
-- sits in that anchor's `deps``, plus `reachable`, the implicit term.
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

-- `<name>` of a tombstone: `tostring(obj)` before death
-- (docs/02-semantics.md, "Tombstones"). An object whose metatable had a
-- `__tostring` had its name captured when it started dying (`decide`);
-- for any other table `tostring` gives `table: 0x…`, which depends only
-- on identity, so it is computed here, on the error path, instead of
-- allocating a string per tombstone.
local function name_of(obj, st)
    local name = st.name
    if name then
        return tostring(name)
    end
    local mt = debug_getmetatable(obj)
    debug_setmetatable(obj, nil)
    name = tostring(obj)
    debug_setmetatable(obj, mt)
    return name
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
-- Dependents lists
------------------------------------------------------------------------

-- docs/03-runtime.md, "The state of an object": "When holes outnumber
-- live entries the runtime compacts: it renumbers the live entries
-- densely from `lo`, in order, updates each dependent's stored sequence
-- number, and resets `seq`." Called from `link` only, never during a
-- destroy phase. Returns the next free sequence number.
local function compact(anchor, deps)
    local lo, seq = deps.lo, deps.seq
    local live = 0
    for i = lo, seq - 1 do
        if deps[i] ~= nil then
            live = live + 1
        end
    end
    if seq - lo - live > live then
        local to = lo
        for from = lo, seq - 1 do
            local dep = deps[from]
            if dep ~= nil then
                if from ~= to then
                    deps[to] = dep
                    deps[from] = nil
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
-- (docs/03-runtime.md, "Attachment", step 4).
local function link(anchor, ast, obj)
    local deps = ast.deps
    if not deps then
        deps = setmetatable({seq = 1, lo = 1, limit = MIN_LIMIT}, WEAK_VALUES)
        ast.deps = deps
    end
    local s = deps.seq
    if s - deps.lo >= deps.limit and phase_depth == 0 then
        s = compact(anchor, deps)
    end
    deps[s] = obj
    deps.seq = s + 1
    return s
end

-- Unlink the entry `s` from an anchor's list (docs/03-runtime.md,
-- "Attachment", step 3, and "The cascade", the tombstone step). The
-- range shrinks when the entry was at either end, so attach-then-destroy
-- in either order leaves no holes to compact; a list that empties starts
-- again at 1. Neither renumbers anything, so it is safe while a cascade
-- walks this list: the walk's bounds are fixed when it starts.
local function unlink(ast, s)
    local deps = ast.deps
    if not deps then
        return
    end
    deps[s] = nil
    local lo, seq = deps.lo, deps.seq
    if s == seq - 1 then
        s = s - 1
        while s >= lo and deps[s] == nil do
            s = s - 1
        end
        if s < lo then
            deps.lo, deps.seq = 1, 1
        else
            deps.seq = s + 1
        end
    elseif s == lo then
        s = s + 1
        while s < seq and deps[s] == nil do
            s = s + 1
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
    local ok, err2 = pcall(handler, obj, err)
    if not ok then
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
local function decide(obj, st, id)
    st.phase = "dying"
    st.phase_id = id
    local mt = debug_getmetatable(obj)
    if mt ~= nil and rawget(mt, "__tostring") ~= nil then
        local ok, name = pcall(tostring, obj)
        if ok then
            st.name = name
        end
    end
    local deps = st.deps
    if deps then
        for i = deps.seq - 1, deps.lo, -1 do
            local dep = deps[i]
            if dep ~= nil then
                local dst = rawget(dep, STATE)
                if not dst.phase then
                    decide(dep, dst, id)
                end
            end
        end
    end
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
    -- as `__destroy(obj, reason)`, in protected mode to route its error.
    if not skip_body then
        local mt = debug_getmetatable(obj)
        local body = mt ~= nil and rawget(mt, "__destroy")
        if body then
            local ok, err = pcall(body, obj, reason)
            if not ok then
                route(obj, err)
            end
        end
    end

    -- 2.2: the dependents, newest first: a numeric loop over the range,
    -- skipping holes (CLAUDE.md, "Technical decisions"). The bounds are
    -- read once; nothing can be linked to a dying anchor, and unlinking
    -- only empties slots.
    local deps = st.deps
    if deps then
        for i = deps.seq - 1, deps.lo, -1 do
            local dep = deps[i]
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
    for j = 1, 2 * st.n, 2 do
        unlink(rawget(st[j], STATE), st[j + 1])
        st[j] = nil
        st[j + 1] = nil
    end
    for k in next, obj do
        if k ~= STATE then
            obj[k] = nil
        end
    end
    debug_setmetatable(obj, DEAD_MT)
    st.n = 0
    st.deps = false
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
local function cascade(root, st, reason, where, skip_body)
    local id = phase_counter + 1
    phase_counter = id
    if not st.phase then
        decide(root, st, id)
    end
    local outer_id, outer_held, outer_error = phase_id, held, held_error
    phase_id, phase_depth, held, held_error = id, phase_depth + 1, false, nil
    destroy_object(root, st, reason, where, skip_body)
    local raise, err = held, held_error
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
function lifetime.destroy(obj)
    local st = destroy_target(obj, "destroy")
    if st then
        cascade(obj, st, "destroy", where_of_caller(), false)
    end
end

-- "`discard(obj)` does the same but skips `obj`'s own destructor".
function lifetime.discard(obj)
    local st = destroy_target(obj, "discard")
    if st then
        cascade(obj, st, "destroy", where_of_caller(), true)
    end
end

------------------------------------------------------------------------
-- Attachment
------------------------------------------------------------------------

-- docs/02-semantics.md, "Acquiring a lifetime", step 2, for one element:
-- a live table, or a lifetime value whose anchors are all live. Returns
-- whether the element carries the `reachable` term ("The implicit
-- `reachable` term": a table carries it; a value carries it if it does).
local function check_anchor(a)
    if type(a) ~= "table" then
        error("attempt to anchor to a " .. type(a) .. " value", 3)
    end
    local ast = rawget(a, STATE)
    if ast then
        local phase = ast.phase
        if phase then
            error("attempt to anchor to a " .. phase .. " table", 3)
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
                error("attempt to anchor to a " .. phase .. " table", 3)
            end
        end
        return a.reachable
    end
    return true
end

-- Link `obj` (record `st`) to the anchors of element `a`, from pair
-- index `k` on; returns the next pair index.
local function link_element(obj, st, a, k)
    if rawget(a, STATE) == nil and is_value(a) then
        for i = 1, a.n do
            local anchor = a[i]
            st[k] = anchor
            st[k + 1] = link(anchor, rawget(anchor, STATE) or new_state(anchor), obj)
            k = k + 2
        end
        return k
    end
    local ast = rawget(a, STATE) or new_state(a)
    st[k] = a
    st[k + 1] = link(a, ast, obj)
    return k + 2
end

-- docs/03-runtime.md, "Attachment: what `@` does": `lifetime.attach(obj,
-- pin, a1, …, an)` performs steps 1 to 4 of docs/02-semantics.md,
-- "Acquiring a lifetime", and returns `obj`. `pin` true attaches without
-- the implicit `reachable` term (hooks, task 003); otherwise the formula
-- carries it when any element does ("The implicit `reachable` term").
-- The term is only recorded here; its effect is task 004's.
function lifetime.attach(obj, pin, ...)
    local count = select("#", ...)
    local t = type(obj)

    -- The common case, without a call: one anchor, a live table the
    -- runtime has seen, and an object that is new to the runtime or alive
    -- with one anchor, outside any destroy phase. It does exactly what
    -- the general path below does for these arguments; anything else
    -- falls through to it.
    if count == 1 and t == "table" and phase_depth == 0 then
        local a = ...
        local ast = type(a) == "table" and rawget(a, STATE)
        if ast and not ast.phase then
            local st = rawget(obj, STATE)
            if st == nil then
                if getmetatable(obj) ~= "lifetime" then
                    st = new_state(obj)
                    st[1] = a
                    st[2] = link(a, ast, obj)
                    st.n = 1
                    st.reachable = not pin
                    return obj
                end
            elseif not st.phase and st.n == 1 then
                unlink(rawget(st[1], STATE), st[2])
                st[1] = a
                st[2] = link(a, ast, obj)
                st.reachable = not pin
                return obj
            end
        end
    end

    -- Step 1: an object.
    if t ~= "table" then
        if t == "function" or t == "thread" or t == "userdata" then
            not_implemented("attach")
        end
        error("attempt to anchor a " .. t .. " value", 2)
    end

    -- Step 2: every element, left to right, before anything changes.
    local term = false
    if count == 1 then
        term = check_anchor((...))
    else
        if count == 0 then
            error("bad argument #3 to 'lifetime.attach' (anchor expected, got no value)", 2)
        end
        for i = 1, count do
            if check_anchor((select(i, ...))) then
                term = true
            end
        end
    end

    -- Step 3: the object itself.
    local st = rawget(obj, STATE)
    if st then
        local phase = st.phase
        if phase == "dying" then
            error("attempt to move a dying table", 2)
        elseif phase == "dead" then
            -- "If `e` is dead, the dead metatable raises first".
            error(dead_message(obj, st, "index"), 2)
        end
        -- docs/02-semantics.md, "No moves during destruction": only
        -- objects on the default formula or created during the innermost
        -- running destroy phase may be moved.
        if phase_depth > 0 and (st.n > 0 or not st.reachable) and st.phase_id ~= phase_id then
            error("attempt to move an anchored table during destruction", 2)
        end
    else
        if is_value(obj) then
            error("attempt to anchor a lifetime value", 2)
        end
        st = new_state(obj)
    end

    -- Step 4: replace the formula; leave the old anchors' lists, join the
    -- new ones' at the end.
    local old = 2 * st.n
    for j = 1, old, 2 do
        unlink(rawget(st[j], STATE), st[j + 1])
    end
    local k = 1
    if count == 1 then
        k = link_element(obj, st, (...), k)
    else
        for i = 1, count do
            k = link_element(obj, st, (select(i, ...)), k)
        end
    end
    for j = k, old do
        st[j] = nil
    end
    st.n = (k - 1) / 2
    st.reachable = term and not pin
    return obj
end

------------------------------------------------------------------------
-- Inspection
------------------------------------------------------------------------

local function value_of(st)
    local n = st.n
    if n == 0 and st.reachable then
        return REACHABLE
    end
    local v = new_value(n, st.reachable)
    for i = 1, n do
        v[i] = st[2 * i - 1]
    end
    return v
end

-- docs/02-semantics.md, "The `lifetime` table": "`lifetime.of(obj)`:
-- `obj`'s current formula as a lifetime value, a snapshot ... Error on
-- `nil`, a value, a dead object." Passing an object to `of` makes the
-- runtime see it ("`__destroy` and reasons", rule 7); on the default
-- lifetime it returns `lifetime.reachable`.
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
        if st.phase == "dead" then
            error(dead_message(obj, st, "index"), 2)
        end
        return value_of(st)
    end
    if is_value(obj) then
        error("bad argument #1 to 'lifetime.of' (object expected, got lifetime)", 2)
    end
    new_state(obj)
    return REACHABLE
end

-- "`lifetime.dependents(obj)`: A fresh array of the live objects and
-- hooks whose formula mentions `obj`, in attachment order." Oldest first:
-- the same numeric loop as the cascade, the other way. Does not make the
-- runtime see `obj`.
function lifetime.dependents(obj)
    local t = type(obj)
    if t ~= "table" and t ~= "function" and t ~= "thread" and t ~= "userdata" then
        error("bad argument #1 to 'lifetime.dependents' (object expected, got " .. t .. ")", 2)
    end
    local result = {}
    local st = t == "table" and rawget(obj, STATE)
    local deps = st and st.deps
    if deps then
        local n = 0
        for i = deps.lo, deps.seq - 1 do
            local dep = deps[i]
            if dep ~= nil then
                n = n + 1
                result[n] = dep
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
-- renders as `dead <name>`." Tokens and hooks are tasks 003 and 004.
function lifetime.format(v)
    if type(v) ~= "table" then
        error("bad argument #1 to 'lifetime.format' (lifetime expected, got " .. type(v) .. ")", 2)
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

return lifetime
