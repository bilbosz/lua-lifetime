-- tests/test-runtime.lua: lifetime/init.lua, task 002. Anchors and the
-- state record, `attach`, `destroy`, `discard`, the cascade in the order
-- of decision 10, tombstones, `destroyerror`, lifetime values, `of`,
-- `dependents`, `format`, `is_state`.
--
-- Every destruction test logs into a table and compares the whole
-- sequence, with the reason, and checks the log before and after the
-- statement that caused the deaths (CLAUDE.md, rule 3).
local test = require("tests.lib.test")
local lifetime = require("lifetime")

local attach, destroy, discard = lifetime.attach, lifetime.destroy, lifetime.discard

local THIS_FILE = debug.getinfo(1, "S").short_src

-- The line of the caller, as `chunk:line` for a tombstone's `<where>`.
local function here()
    return THIS_FILE .. ":" .. debug.getinfo(2, "l").currentline
end

-- A logging object: `__tostring` gives `name`, `__destroy` appends
-- `name (reason)` to `log`, and `extra(self, reason)` runs inside the body
-- when given.
local function new_logged(log, name, extra)
    local mt = {}
    mt.__tostring = function()
        return name
    end
    mt.__destroy = function(self, reason)
        log[#log + 1] = name .. " (" .. reason .. ")"
        if extra then
            extra(self, reason)
        end
    end
    return setmetatable({}, mt)
end

-- The state record of a table, found the way a user would skip it.
local function state_of(t)
    for k, v in pairs(t) do
        if lifetime.is_state(k) then
            return v
        end
    end
    return nil
end

local function field_count(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

-- The keys of `t` other than the state record.
local function user_keys(t)
    local n = 0
    for k in pairs(t) do
        if not lifetime.is_state(k) then
            n = n + 1
        end
    end
    return n
end

-- Run `fn` with `_G.destroyerror` set to `handler` (nil for the default)
-- and `io.stderr` replaced by a buffer; returns what was written.
local function with_handler(handler, fn)
    local saved_handler, saved_stderr = rawget(_G, "destroyerror"), io.stderr
    local written = {}
    rawset(io, "stderr", {
        write = function(self, ...)
            for i = 1, select("#", ...) do
                written[#written + 1] = tostring((select(i, ...)))
            end
            return self
        end
    })
    rawset(_G, "destroyerror", handler)
    local ok, err = pcall(fn)
    rawset(_G, "destroyerror", saved_handler)
    rawset(io, "stderr", saved_stderr)
    if not ok then
        error(err, 0)
    end
    return table.concat(written)
end

test.suite("runtime: the state record")

test.case("a table never anchored gets no state record", function()
    local t = {x = 1}
    local a = {}
    test.assert_eq(#lifetime.dependents(t), 0)
    test.assert_eq(lifetime.format(t), "reachable")
    test.assert_eq(field_count(t), 1, "dependents and format leave the table alone")
    -- Being used as an anchor makes it seen; the dependent too.
    local x = attach({}, false, a)
    test.assert_true(state_of(a) ~= nil)
    test.assert_true(state_of(x) ~= nil)
    test.assert_eq(state_of(t), nil)
end)

test.case("a pairs loop finds exactly one key for which is_state is true; the key is the same in every table", function()
    local a, b = {}, {}
    local x = attach({v = 1}, false, a)
    attach(b, false, a)
    local keys = {}
    for k in pairs(x) do
        if lifetime.is_state(k) then
            keys[#keys + 1] = k
        end
    end
    test.assert_eq(#keys, 1)
    test.assert_eq(type(keys[1]), "table", "the key is a private table")
    local key_b
    for k in pairs(b) do
        if lifetime.is_state(k) then
            key_b = k
        end
    end
    test.assert_true(rawequal(keys[1], key_b))
    test.assert_eq(user_keys(x), 1)
    test.assert_eq(x.v, 1)
end)

test.case("is_state is false for everything else", function()
    test.assert_false(lifetime.is_state(nil))
    test.assert_false(lifetime.is_state("state"))
    test.assert_false(lifetime.is_state({}))
    test.assert_false(lifetime.is_state(lifetime))
    test.assert_false(lifetime.is_state(lifetime.reachable))
    test.assert_false(lifetime.is_state(1))
end)

test.suite("runtime: attach")

test.case("attach returns obj, links at the end of each anchor's list, keeps the anchors in the record", function()
    local a, c = {}, {}
    local b = {}
    test.assert_true(rawequal(attach(b, false, a), b))
    local d = attach({}, false, a, c)
    test.assert_deep_eq(lifetime.dependents(a), {b, d})
    test.assert_deep_eq(lifetime.dependents(c), {d})
    test.assert_deep_eq(lifetime.dependents(d), {})
    test.assert_eq(lifetime.format(lifetime.of(d)), "(" .. tostring(a) .. ", " .. tostring(c) .. ", reachable)")
end)

test.case("a move replaces the formula: unlinks from the old anchors, joins the end of the new lists", function()
    local a, b, c = {}, {}, {}
    local x = attach({}, false, a)
    local y = attach({}, false, a, b)
    local z = attach({}, false, b)
    attach(x, false, b, c)
    test.assert_deep_eq(lifetime.dependents(a), {y})
    test.assert_deep_eq(lifetime.dependents(b), {y, z, x})
    test.assert_deep_eq(lifetime.dependents(c), {x})
    -- Re-attaching to the same anchor moves to the end of its list.
    attach(y, false, b)
    test.assert_deep_eq(lifetime.dependents(a), {})
    test.assert_deep_eq(lifetime.dependents(b), {z, x, y})
    -- The record keeps no stale anchors after shrinking.
    local st = state_of(x)
    attach(x, false, a)
    test.assert_eq(st.n, 1)
    test.assert_eq(rawget(st, 3), nil)
    test.assert_eq(rawget(st, 4), nil)
    test.assert_deep_eq(lifetime.dependents(c), {})
end)

test.case("a move carries the object's own dependents with it", function()
    local log = {}
    local a, b = {}, {}
    local x = attach(new_logged(log, "x"), false, a)
    local y = attach(new_logged(log, "y"), false, x)
    attach(x, false, b)
    test.assert_deep_eq(lifetime.dependents(x), {y})
    destroy(a)
    test.assert_deep_eq(log, {})
    destroy(b)
    test.assert_deep_eq(log, {"x (anchor)", "y (anchor)"})
end)

test.case("x @ lifetime.reachable releases the object: no anchors, default formula", function()
    local a = {}
    local x = attach({}, false, a)
    attach(x, false, lifetime.reachable)
    test.assert_deep_eq(lifetime.dependents(a), {})
    test.assert_true(rawequal(lifetime.of(x), lifetime.reachable))
    test.assert_eq(lifetime.format(x), "reachable")
end)

test.case("step 1: the object must be an object", function()
    local a = {}
    test.assert_error(function()
        attach(5, false, a)
    end, "attempt to anchor a number value")
    test.assert_error(function()
        attach(nil, false, a)
    end, "attempt to anchor a nil value")
    test.assert_error(function()
        attach("s", false, a)
    end, "attempt to anchor a string value")
    test.assert_error(function()
        attach(lifetime.reachable, false, a)
    end, "attempt to anchor a lifetime value")
end)

test.case("step 2: each anchor must be a live table or a lifetime value", function()
    local x = {}
    test.assert_error(function()
        attach(x, false, nil)
    end, "attempt to anchor to a nil value")
    test.assert_error(function()
        attach(x, false, 5)
    end, "attempt to anchor to a number value")
    test.assert_error(function()
        attach(x, false, print)
    end, "attempt to anchor to a function value")
    test.assert_error(function()
        attach(x, false, coroutine.create(function() end))
    end, "attempt to anchor to a thread value")
    local a = {}
    test.assert_error(function()
        attach(x, false, a, nil)
    end, "attempt to anchor to a nil value")
    local dead = {}
    destroy(dead)
    test.assert_error(function()
        attach(x, false, a, dead)
    end, "attempt to anchor to a dead table")
    -- A failed attach changes nothing.
    test.assert_deep_eq(lifetime.dependents(a), {})
    test.assert_eq(state_of(x), nil)
end)

test.case("the error position is the attach call's", function()
    local err = test.assert_error(function()
        attach(5, false, {})
    end, "attempt to anchor a number value")
    test.assert_eq(err:sub(1, #THIS_FILE), THIS_FILE)
end)

test.case("anchoring to a dying object raises; a fresh object anchored elsewhere during the phase works", function()
    local log = {}
    local other = {}
    local fresh
    local a = new_logged(log, "a", function(self)
        test.assert_error(function()
            attach({}, false, self)
        end, "attempt to anchor to a dying table")
        fresh = attach({}, false, other)
    end)
    destroy(a)
    test.assert_deep_eq(log, {"a (destroy)"})
    test.assert_deep_eq(lifetime.dependents(other), {fresh})
end)

test.suite("runtime: no moves during destruction")

test.case("case 5: moving an older anchored table raises; a table created in the phase can be anchored and moved", function()
    local log = {}
    local other, elsewhere = {}, {}
    local b = attach({}, false, elsewhere)
    local fresh
    local errs = {}
    local A = new_logged(log, "A", function(self)
        errs[1] = select(2, pcall(attach, self.b, false, other))
        fresh = attach({}, false, other)
        attach(fresh, false, elsewhere)
        -- An older table on the default formula may be anchored.
        attach(self.plain, false, other)
    end)
    A.b = b
    A.plain = {}
    local plain = A.plain
    lifetime.of(plain) -- seen before the phase, still on the default formula
    destroy(A)
    test.assert_deep_eq(log, {"A (destroy)"})
    test.assert_true(errs[1]:find("attempt to move an anchored table during destruction", 1, true) ~= nil, errs[1])
    test.assert_deep_eq(lifetime.dependents(other), {plain})
    test.assert_deep_eq(lifetime.dependents(elsewhere), {b, fresh})
    -- After the phase the old table moves freely again.
    attach(b, false, other)
    test.assert_deep_eq(lifetime.dependents(other), {plain, b})
end)

test.case("a dying object cannot be moved, so a body cannot rescue a sibling", function()
    local log = {}
    local safe = {}
    local err
    local a = new_logged(log, "a")
    local sibling = attach(new_logged(log, "sibling"), false, a)
    getmetatable(a).__destroy = function(self, reason)
        log[#log + 1] = "a (" .. reason .. ")"
        err = select(2, pcall(attach, sibling, false, safe))
    end
    destroy(a)
    test.assert_true(err:find("attempt to move a dying table", 1, true) ~= nil, err)
    test.assert_deep_eq(log, {"a (destroy)", "sibling (anchor)"})
    test.assert_eq(getmetatable(sibling), "dead")
    test.assert_deep_eq(lifetime.dependents(safe), {})
end)

test.case("an object created in an outer phase is not exempt in a nested one", function()
    local log = {}
    local other = {}
    local made, err
    local inner = new_logged(log, "inner", function()
        err = select(2, pcall(attach, made, false, other))
    end)
    local outer = new_logged(log, "outer", function()
        made = attach({}, false, other)
        destroy(inner)
    end)
    destroy(outer)
    test.assert_deep_eq(log, {"outer (destroy)", "inner (destroy)"})
    test.assert_true(err:find("attempt to move an anchored table during destruction", 1, true) ~= nil, err)
end)

test.suite("runtime: destroy and the cascade")

test.case("case 1: the worked example without the hook: c, d, then a, b", function()
    local log = {}
    local a = new_logged(log, "a")
    local b = attach(new_logged(log, "b"), false, a)
    local c = new_logged(log, "c")
    local d = attach(new_logged(log, "d"), false, a, c)
    test.assert_deep_eq(log, {})
    local where_c = here(); destroy(c)
    test.assert_deep_eq(log, {"c (destroy)", "d (anchor)"})
    test.assert_deep_eq(lifetime.dependents(a), {b})
    local where_a = here(); destroy(a)
    test.assert_deep_eq(log, {"c (destroy)", "d (anchor)", "a (destroy)", "b (anchor)"})
    -- Tombstones.
    test.assert_eq(getmetatable(d), "dead")
    test.assert_eq(getmetatable(b), "dead")
    test.assert_error(function()
        return d.x
    end, "attempt to index a dead table (d, died at " .. where_c .. ", anchor)")
    test.assert_error(function()
        return a.x
    end, "attempt to index a dead table (a, died at " .. where_a .. ", destroy)")
    test.assert_error(function()
        return b.x
    end, "attempt to index a dead table (b, died at " .. where_a .. ", anchor)")
end)

test.case("the same example as one cascade: decide first, then newest first, a dependent reached twice dies once", function()
    local log = {}
    local root = {}
    local a = attach(new_logged(log, "a"), false, root)
    attach(new_logged(log, "b"), false, a)
    local c = attach(new_logged(log, "c"), false, root)
    attach(new_logged(log, "d"), false, a, c)
    destroy(root)
    test.assert_deep_eq(log, {"c (anchor)", "d (anchor)", "a (anchor)", "b (anchor)"})
end)

test.case("case 2: the body runs before the dependents and sees them alive", function()
    local log = {}
    local conn = new_logged(log, "conn", function(self)
        log[#log + 1] = "conn sees " .. self.buf.n
    end)
    conn.buf = attach(setmetatable({n = 1}, {
        __destroy = function(self, reason)
            log[#log + 1] = "buf (" .. reason .. ") n=" .. self.n
        end
    }), false, conn)
    local where = here(); destroy(conn)
    test.assert_deep_eq(log, {"conn (destroy)", "conn sees 1", "buf (anchor) n=1"})
    test.assert_error(function()
        return conn.buf
    end, "attempt to index a dead table (conn, died at " .. where .. ", destroy)")
end)

test.case("dependents die newest first, each with its whole subtree before the next", function()
    local log = {}
    local root = new_logged(log, "root")
    local x = attach(new_logged(log, "x"), false, root)
    attach(new_logged(log, "x1"), false, x)
    attach(new_logged(log, "x2"), false, x)
    local y = attach(new_logged(log, "y"), false, root)
    attach(new_logged(log, "y1"), false, y)
    attach(new_logged(log, "z"), false, root)
    destroy(root)
    test.assert_deep_eq(log, {"root (destroy)", "z (anchor)", "y (anchor)", "y1 (anchor)", "x (anchor)", "x2 (anchor)", "x1 (anchor)"})
end)

test.case("destroying an object does not affect its anchors", function()
    local log = {}
    local a = new_logged(log, "a")
    local x = attach(new_logged(log, "x"), false, a)
    local y = attach(new_logged(log, "y"), false, a)
    destroy(x)
    test.assert_deep_eq(log, {"x (destroy)"})
    test.assert_eq(type(getmetatable(a)), "table", "a keeps its metatable")
    test.assert_deep_eq(lifetime.dependents(a), {y})
    destroy(a)
    test.assert_deep_eq(log, {"x (destroy)", "a (destroy)", "y (anchor)"})
end)

test.case("case 3: destroy by hand inside a body runs the dependent now; the later pass skips it", function()
    local log = {}
    local A = new_logged(log, "A", function(self)
        destroy(self.child)
        log[#log + 1] = "A after destroy(child)"
    end)
    attach(new_logged(log, "first"), false, A)
    A.child = attach(new_logged(log, "child"), false, A)
    attach(new_logged(log, "grandchild"), false, A.child)
    attach(new_logged(log, "last"), false, A)
    destroy(A)
    test.assert_deep_eq(log, {"A (destroy)", "child (destroy)", "grandchild (anchor)", "A after destroy(child)", "last (anchor)", "first (anchor)"})
end)

test.case("destroy and discard on a dying object whose destruction has begun, or on a dead one, are no-ops", function()
    local log = {}
    local a
    a = new_logged(log, "a", function(self)
        destroy(self)
        discard(self)
    end)
    attach(new_logged(log, "b"), false, a)
    destroy(a)
    test.assert_deep_eq(log, {"a (destroy)", "b (anchor)"})
    destroy(a)
    discard(a)
    test.assert_deep_eq(log, {"a (destroy)", "b (anchor)"})
end)

test.case("a dependent's body may destroy its anchor's other dependents; each dies once", function()
    local log = {}
    local root = new_logged(log, "root")
    local older = attach(new_logged(log, "older"), false, root)
    attach(new_logged(log, "newer", function()
        destroy(older)
    end), false, root)
    destroy(root)
    test.assert_deep_eq(log, {"root (destroy)", "newer (anchor)", "older (destroy)"})
end)

test.case("destroy(nil) is a no-op; destroy(5) and discard(true) raise the argument error", function()
    destroy(nil)
    discard(nil)
    local err = test.assert_error(function()
        destroy(5)
    end, "bad argument #1 to 'destroy' (object expected, got number)")
    test.assert_eq(err:sub(1, #THIS_FILE), THIS_FILE)
    test.assert_error(function()
        discard(true)
    end, "bad argument #1 to 'discard' (object expected, got boolean)")
    test.assert_error(function()
        destroy("s")
    end, "bad argument #1 to 'destroy' (object expected, got string)")
end)

test.case("destroy works on a table on the default lifetime the runtime never saw", function()
    local log = {}
    local t = new_logged(log, "t")
    t.x = 1
    destroy(t)
    test.assert_deep_eq(log, {"t (destroy)"})
    test.assert_eq(getmetatable(t), "dead")
end)

test.case("discard skips the object's own body only", function()
    local log = {}
    local a = new_logged(log, "a")
    local b = attach(new_logged(log, "b"), false, a)
    attach(new_logged(log, "c"), false, b)
    local where = here(); discard(a)
    test.assert_deep_eq(log, {"b (anchor)", "c (anchor)"})
    test.assert_eq(getmetatable(a), "dead")
    test.assert_error(function()
        return a.x
    end, "attempt to index a dead table (a, died at " .. where .. ", destroy)")
end)

test.case("a cycle of anchors: each object dies once", function()
    local log = {}
    local x = new_logged(log, "x")
    local y = attach(new_logged(log, "y"), false, x)
    attach(x, false, y)
    destroy(x)
    test.assert_deep_eq(log, {"x (destroy)", "y (anchor)"})
    local self_anchored = attach(new_logged(log, "s"), false, {})
    attach(self_anchored, false, self_anchored)
    destroy(self_anchored)
    test.assert_deep_eq(log, {"x (destroy)", "y (anchor)", "s (destroy)"})
end)

test.case("__destroy is read from the metatable at the moment of death", function()
    local log = {}
    local mt = {}
    local x = setmetatable({}, mt)
    local a = {}
    attach(x, false, a)
    mt.__destroy = function(_, reason)
        log[#log + 1] = "late (" .. reason .. ")"
    end
    destroy(a)
    test.assert_deep_eq(log, {"late (anchor)"})
end)

test.case("a protected metatable: __destroy still runs and the table is still tombstoned", function()
    local log = {}
    local x = setmetatable({}, {
        __metatable = "mine",
        __destroy = function(_, reason)
            log[#log + 1] = "x (" .. reason .. ")"
        end
    })
    destroy(x)
    test.assert_deep_eq(log, {"x (destroy)"})
    test.assert_eq(getmetatable(x), "dead")
end)

test.case("a __newindex on the object does not stop the runtime", function()
    local x = setmetatable({}, {
        __newindex = function()
            error("read-only")
        end
    })
    local a = {}
    attach(x, false, a)
    test.assert_deep_eq(lifetime.dependents(a), {x})
    destroy(a)
    test.assert_eq(getmetatable(x), "dead")
end)

test.suite("runtime: tombstones")

test.case("a tombstone is empty, has the dead metatable and raises with name, where and reason", function()
    local x = setmetatable({1, 2, 3, k = "v"}, {
        __tostring = function(self)
            return "conn " .. self.k
        end
    })
    local a = {}
    attach(x, false, a)
    local where = here(); destroy(a)
    test.assert_eq(user_keys(x), 0, "every field cleared, the array part included")
    test.assert_eq(field_count(x), 1, "only the state record is left")
    test.assert_eq(rawget(x, 1), nil)
    test.assert_eq(rawget(x, "k"), nil)
    test.assert_eq(#x, 0)
    test.assert_eq(getmetatable(x), "dead")
    test.assert_eq(tostring(x), "dead conn v")
    test.assert_true(x == x)
    test.assert_false(x == {})
    local suffix = " a dead table (conn v, died at " .. where .. ", anchor)"
    test.assert_error(function()
        return x.k
    end, "attempt to index" .. suffix)
    test.assert_error(function()
        x.k = 1
    end, "attempt to assign to" .. suffix)
    test.assert_error(function()
        x()
    end, "attempt to call" .. suffix)
    test.assert_error(function()
        setmetatable(x, {})
    end, "cannot change a protected metatable")
    -- rawset does not raise.
    rawset(x, "r", 1)
    test.assert_eq(rawget(x, "r"), 1)
end)

test.case("the error position of a tombstone access is the accessing line", function()
    local x = {}
    destroy(x)
    local err = test.assert_error(function()
        return x.y
    end, "attempt to index a dead table")
    test.assert_eq(err:sub(1, #THIS_FILE), THIS_FILE)
end)

test.case("without __tostring the name is the table's own tostring before death", function()
    local x = {}
    local name = tostring(x)
    local where = here(); destroy(x)
    test.assert_eq(tostring(x), "dead " .. name)
    test.assert_error(function()
        return x.y
    end, "attempt to index a dead table (" .. name .. ", died at " .. where .. ", destroy)")
    test.assert_eq(getmetatable(x), "dead")
end)

test.case("identity survives death: a tombstone still finds its entry as a key", function()
    local x = {}
    local set = {[x] = "found"}
    destroy(x)
    test.assert_eq(set[x], "found")
end)

test.case("<where> of a destroy inside a body is that body's destroy call", function()
    local log = {}
    local inner = new_logged(log, "inner")
    local where
    local outer = new_logged(log, "outer", function()
        where = here(); destroy(inner)
    end)
    destroy(outer)
    test.assert_error(function()
        return inner.x
    end, "(inner, died at " .. where .. ", destroy)")
end)

test.case("attach on a dead object raises the tombstone's message", function()
    local x = {}
    local where = here(); destroy(x)
    test.assert_error(function()
        attach(x, false, {})
    end, "attempt to index a dead table (" .. tostring(x):sub(6) .. ", died at " .. where .. ", destroy)")
end)

test.suite("runtime: errors in destructors")

-- A table whose body raises `message` (unpositioned) after logging.
local function raising(log, name, message)
    return setmetatable({}, {
        __destroy = function()
            log[#log + 1] = name
            error(message, 0)
        end
    })
end

test.case("case 4: the first error is re-raised after the cascade; later ones go to destroyerror in order", function()
    local log, routed = {}, {}
    local root = {}
    local one = attach(raising(log, "one", "one"), false, root)
    local two = attach(raising(log, "two", "two"), false, root)
    attach(raising(log, "three", "three"), false, root)
    attach(new_logged(log, "newest"), false, root)
    local ok, err
    with_handler(function(obj, e)
        routed[#routed + 1] = {obj, e}
        test.assert_true(lifetime.dependents(obj) ~= nil, "the object is still usable")
    end, function()
        ok, err = pcall(destroy, root)
    end)
    test.assert_false(ok)
    test.assert_eq(err, "three")
    test.assert_deep_eq(log, {"newest (anchor)", "three", "two", "one"})
    test.assert_eq(#routed, 2)
    test.assert_true(rawequal(routed[1][1], two))
    test.assert_eq(routed[1][2], "two")
    test.assert_true(rawequal(routed[2][1], one))
    test.assert_eq(routed[2][2], "one")
    test.assert_eq(getmetatable(root), "dead")
    test.assert_eq(getmetatable(one), "dead")
end)

test.case("the root's own error is the first and is re-raised; the object is dead anyway", function()
    local log = {}
    local root = raising(log, "root", "boom")
    attach(new_logged(log, "dep"), false, root)
    local ok, err = pcall(destroy, root)
    test.assert_false(ok)
    test.assert_eq(err, "boom")
    test.assert_deep_eq(log, {"root", "dep (anchor)"})
    test.assert_eq(getmetatable(root), "dead")
end)

test.case("a destroy inside a body is a cascade of its own: its error raises to that call", function()
    local log = {}
    local caught
    local inner = raising(log, "inner", "inner failed")
    local outer = new_logged(log, "outer", function()
        local ok, err = pcall(destroy, inner)
        caught = {ok, err}
    end)
    destroy(outer) -- does not raise: the body caught it
    test.assert_deep_eq(log, {"outer (destroy)", "inner"})
    test.assert_deep_eq(caught, {false, "inner failed"})
end)

test.case("the default destroyerror writes `destroyerror: <message>` and a traceback to stderr", function()
    local root = {}
    attach(raising({}, "a", "first"), false, root)
    attach(raising({}, "b", "second"), false, root)
    local ok, err
    local written = with_handler(nil, function()
        ok, err = pcall(destroy, root)
    end)
    test.assert_false(ok)
    test.assert_eq(err, "second")
    test.assert_eq(written:sub(1, #"destroyerror: first\n"), "destroyerror: first\n")
    test.assert_true(written:find("stack traceback:", 1, true) ~= nil, written)
end)

test.case("a raising handler: both errors go to stderr and the cascade continues", function()
    local log = {}
    local root = {}
    attach(new_logged(log, "survivor"), false, root)
    attach(raising(log, "a", "first"), false, root)
    attach(raising(log, "b", "second"), false, root)
    local ok, err
    local written = with_handler(function()
        error("handler broke", 0)
    end, function()
        ok, err = pcall(destroy, root)
    end)
    test.assert_false(ok)
    test.assert_eq(err, "second")
    test.assert_deep_eq(log, {"b", "a", "survivor (anchor)"})
    test.assert_eq(written, "destroyerror: first\ndestroyerror: error in destroyerror (handler broke)\n")
end)

test.case("a destroyerror that is not callable: both errors go to stderr", function()
    local root = {}
    attach(raising({}, "a", "first"), false, root)
    attach(raising({}, "b", "second"), false, root)
    local written = with_handler(42, function()
        pcall(destroy, root)
    end)
    test.assert_true(written:find("destroyerror: first\ndestroyerror: error in destroyerror (", 1, true) == 1, written)
end)

test.case("destroyerror is read raw from _G", function()
    local routed = {}
    local root = {}
    attach(raising({}, "a", "first"), false, root)
    attach(raising({}, "b", "second"), false, root)
    local saved_mt = getmetatable(_G)
    with_handler(function(_, e)
        routed[#routed + 1] = e
    end, function()
        setmetatable(_G, {
            __index = function()
                error("must not be consulted")
            end
        })
        pcall(destroy, root)
        setmetatable(_G, saved_mt)
    end)
    test.assert_deep_eq(routed, {"first"})
end)

test.suite("runtime: lifetime values, of, format, dependents")

test.case("of returns a value with the metatable lifetime; format renders the formula", function()
    local a = setmetatable({}, {
        __tostring = function()
            return "a"
        end
    })
    local b = setmetatable({}, {
        __tostring = function()
            return "b"
        end
    })
    local x = attach({}, false, a)
    local v = lifetime.of(x)
    test.assert_eq(getmetatable(v), "lifetime")
    test.assert_eq(lifetime.format(v), "(a, reachable)")
    test.assert_eq(lifetime.format(x), "(a, reachable)")
    attach(x, false, a, b)
    test.assert_eq(lifetime.format(lifetime.of(x)), "(a, b, reachable)")
    -- A snapshot: the earlier value did not change.
    test.assert_eq(lifetime.format(v), "(a, reachable)")
    -- Pinned (the `pin` flag, as hooks use it): no term.
    local p = attach({}, true, a)
    test.assert_eq(lifetime.format(lifetime.of(p)), "a")
    attach(p, true, a, b)
    test.assert_eq(lifetime.format(lifetime.of(p)), "(a, b)")
    -- The default lifetime of a seen object.
    local seen = {}
    test.assert_true(rawequal(lifetime.of(seen), lifetime.reachable))
    test.assert_eq(lifetime.format(lifetime.of(seen)), "reachable")
    test.assert_eq(getmetatable(lifetime.reachable), "lifetime")
end)

test.case("of makes the runtime see the object", function()
    local log = {}
    local t = new_logged(log, "t")
    test.assert_eq(state_of(t), nil)
    lifetime.of(t)
    test.assert_true(state_of(t) ~= nil)
end)

test.case("of raises on nil, a value and a dead object", function()
    test.assert_error(function()
        lifetime.of(nil)
    end, "bad argument #1 to 'lifetime.of' (object expected, got nil)")
    test.assert_error(function()
        lifetime.of(5)
    end, "bad argument #1 to 'lifetime.of' (object expected, got number)")
    local x = {}
    destroy(x)
    test.assert_error(function()
        lifetime.of(x)
    end, "attempt to index a dead table")
end)

test.case("a value is spliced: its anchors and its term; the implicit term is added unless every element is pinned", function()
    local a, b = {}, {}
    local x = attach({}, false, a)
    local y = attach({}, false, lifetime.of(x), b)
    test.assert_deep_eq(lifetime.dependents(a), {x, y})
    test.assert_deep_eq(lifetime.dependents(b), {y})
    test.assert_eq(lifetime.format(y), "(" .. tostring(a) .. ", " .. tostring(b) .. ", reachable)")
    local p = attach({}, true, a)
    local q = attach({}, false, lifetime.of(p))
    test.assert_eq(lifetime.format(q), tostring(a), "a pinned value carries no term")
    local r = attach({}, false, lifetime.of(p), b)
    test.assert_eq(lifetime.format(r), "(" .. tostring(a) .. ", " .. tostring(b) .. ", reachable)", "a table adds the term")
end)

test.case("a value mentioning a dead anchor raises; format renders the dead anchor", function()
    local a = setmetatable({}, {
        __tostring = function()
            return "a"
        end
    })
    local x = attach({}, false, a)
    local v = lifetime.of(x)
    destroy(a)
    test.assert_error(function()
        attach({}, false, v)
    end, "attempt to anchor to a dead table")
    test.assert_eq(lifetime.format(v), "(dead a, reachable)")
end)

test.case("== on two values compares structure", function()
    local a, b = {}, {}
    local x = attach({}, false, a, b)
    local y = attach({}, false, b, a)
    local z = attach({}, true, a, b)
    test.assert_true(lifetime.of(x) == lifetime.of(x))
    test.assert_true(lifetime.of(x) == lifetime.of(y))
    test.assert_false(lifetime.of(x) == lifetime.of(z))
    test.assert_false(lifetime.of(x) == lifetime.of(attach({}, false, a)))
end)

test.case("dependents returns live dependents in attachment order, a fresh array each time", function()
    local a = {}
    local x = attach({}, false, a)
    local y = attach({}, false, a)
    local z = attach({}, false, a)
    local first = lifetime.dependents(a)
    test.assert_deep_eq(first, {x, y, z})
    destroy(y)
    test.assert_deep_eq(lifetime.dependents(a), {x, z})
    test.assert_deep_eq(first, {x, y, z})
    test.assert_false(rawequal(first, lifetime.dependents(a)))
    test.assert_error(function()
        lifetime.dependents(5)
    end, "bad argument #1 to 'lifetime.dependents' (object expected, got number)")
end)

test.case("dependents of a dying anchor, from its body: every dependent alive", function()
    local seen
    local a = setmetatable({}, {
        __destroy = function(self)
            seen = lifetime.dependents(self)
        end
    })
    local x = attach({}, false, a)
    local y = attach({}, false, a)
    destroy(a)
    test.assert_deep_eq(seen, {x, y})
end)

test.suite("runtime: weakness and compaction")

test.case("case 6: a dependent kept only by its anchor's list is collected", function()
    local a = {}
    local probe = setmetatable({}, {__mode = "k"})
    local kept = attach({}, false, a)
    do
        local dropped = attach({}, false, a)
        probe[dropped] = true
    end
    collectgarbage("collect")
    collectgarbage("collect")
    test.assert_eq(next(probe), nil, "the runtime did not keep the dependent alive")
    test.assert_deep_eq(lifetime.dependents(a), {kept})
end)

test.case("an anchor's record holds no strong reference to it: an unreferenced anchor and its dependent are collected", function()
    local probe = setmetatable({}, {__mode = "k"})
    do
        local a = {}
        local x = attach({}, false, a)
        probe[a], probe[x] = true, true
    end
    collectgarbage("collect")
    collectgarbage("collect")
    test.assert_eq(next(probe), nil)
end)

test.case("holes from collected dependents are compacted: the range stays bounded and the order is kept", function()
    local a = {}
    local kept = {}
    -- In a function of its own, so that no stale stack slot keeps the
    -- last temporaries alive when it returns.
    local function fill()
        for i = 1, 2000 do
            local x = attach({i = i}, false, a)
            if i % 100 == 0 then
                kept[#kept + 1] = x
            end
            if i % 50 == 0 then
                collectgarbage("collect")
            end
        end
    end
    fill()
    collectgarbage("collect")
    collectgarbage("collect")
    local deps = state_of(a).deps
    test.assert_true(deps.seq - deps.lo < 300, "range " .. (deps.seq - deps.lo))
    test.assert_deep_eq(lifetime.dependents(a), kept)
    -- Every kept dependent's stored sequence number matches its slot.
    for _, x in ipairs(kept) do
        local xs = state_of(x)
        test.assert_true(rawequal(deps[xs[2]], x))
    end
    -- The order survives destruction after compaction.
    local log = {}
    for i, x in ipairs(kept) do
        setmetatable(x, {
            __destroy = function()
                log[#log + 1] = i
            end
        })
    end
    destroy(a)
    local expected = {}
    for i = #kept, 1, -1 do
        expected[#expected + 1] = i
    end
    test.assert_deep_eq(log, expected)
end)

test.case("explicit unlinks in any order keep the order; a list emptied by moves starts again at 1", function()
    local a, b = {}, {}
    local xs = {}
    for i = 1, 40 do
        xs[i] = attach({i = i}, false, a)
    end
    -- Move every odd one away: holes in the middle.
    for i = 1, 40, 2 do
        attach(xs[i], false, b)
    end
    local expected = {}
    for i = 2, 40, 2 do
        expected[#expected + 1] = xs[i]
    end
    test.assert_deep_eq(lifetime.dependents(a), expected)
    -- New links go after the old ones, compaction or not.
    for i = 41, 80 do
        xs[i] = attach({i = i}, false, a)
        expected[#expected + 1] = xs[i]
    end
    test.assert_deep_eq(lifetime.dependents(a), expected)
    for _, x in ipairs(expected) do
        attach(x, false, b)
    end
    local deps = state_of(a).deps
    test.assert_eq(deps.lo, 1)
    test.assert_eq(deps.seq, 1)
    test.assert_deep_eq(lifetime.dependents(a), {})
end)

test.case("no compaction during a destroy phase", function()
    local a = {}
    local held_dependent = attach({}, false, a)
    local done
    local root = setmetatable({}, {
        __destroy = function()
            local deps = state_of(a).deps
            local seq_before = deps.seq
            -- Fresh objects linked during the phase, then dropped: holes.
            for _ = 1, 200 do
                attach({}, false, a)
            end
            collectgarbage("collect")
            collectgarbage("collect")
            attach({}, false, a)
            done = deps.seq == seq_before + 201
        end
    })
    destroy(root)
    test.assert_true(done)
    test.assert_eq(lifetime.dependents(a)[1], held_dependent)
end)

return test
