-- tests/test-sentinel.lua: lifetime/init.lua, task 004. The implicit
-- `reachable` term and `lifetime.pin`, tokens (`lifetime.token`),
-- `lifetime.alive`, the `newproxy` sentinel that runs a cascade when the
-- collector finds an object, the exit flag, and the follow-ups task 003
-- left for this task (its case 7, a collected suspended coroutine; the
-- nested-coroutine stack swap; `exit(nil)` on an empty stack).
--
-- Every destruction test logs into a table and compares the whole
-- sequence, with the reason, and checks the log before and after the
-- statement that caused the deaths (CLAUDE.md, rule 3). A death by
-- `reachable` is pinned with `collectgarbage("collect")` only, twice when
-- a weak table must have cleared. Objects the collector must find are
-- made inside a helper function that returns, so that no stale stack slot
-- of the test keeps them; objects that must survive are held by the test
-- (CLAUDE.md, rule 6).
local test = require("tests.lib.test")
local lifetime = require("lifetime")

local attach, destroy, discard = lifetime.attach, lifetime.destroy, lifetime.discard
local enter, exit, hook = lifetime.enter, lifetime.exit, lifetime.hook
local token, pin, alive = lifetime.token, lifetime.pin, lifetime.alive

local THIS_FILE = debug.getinfo(1, "S").short_src

local function collect()
    collectgarbage("collect")
end

-- Runs `make` on a coroutine of its own and lets the coroutine go: what
-- `make` created and did not hand out is then referenced by nothing, not
-- even by a stale slot of the test's own stack, which LuaJIT may still
-- scan (seen under an eager collector).
local function run_dropped(make)
    local ok, err = coroutine.resume(coroutine.create(make))
    if not ok then
        error(err, 0)
    end
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

-- A logging hook function: appends `text (reason)`.
local function logger(log, text)
    return function(reason)
        log[#log + 1] = text .. " (" .. tostring(reason) .. ")"
    end
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

-- The sentinel of a table, read through its state record
-- (docs/03-runtime.md, "The state of an object": `sentinel`; as
-- implemented, the record's `reachable` holds the proxy's metatable when
-- the object has one, a scope record's `sentinel` field does). Returns
-- the proxy, or nil. The test of a sentinel is the proxy itself: a
-- `newproxy` userdata whose own metatable holds the owner. A test never
-- keeps a proxy beyond its checks: once its owner dies the runtime may
-- hand it to a later owner, which the kept proxy would then keep alive.
local function sentinel_of(t)
    local st = state_of(t)
    if not st then
        return nil
    end
    local mt = rawget(st, "reachable")
    if type(mt) ~= "table" then
        mt = rawget(st, "sentinel")
    end
    if type(mt) ~= "table" then
        return nil
    end
    local proxy = rawget(mt, "proxy")
    test.assert_eq(type(proxy), "userdata", "the sentinel is a userdata")
    test.assert_true(rawequal(getmetatable(proxy), mt), "the proxy's own metatable")
    test.assert_true(rawequal(rawget(mt, "owner"), t), "the proxy's metatable holds the owner")
    test.assert_eq(type(rawget(mt, "__gc")), "function", "the proxy has a finalizer")
    return proxy
end

-- The depth of the running coroutine's scope stack, read through a fresh
-- record (its `depth` is one more), which is then exited at once.
local function depth()
    local probe = enter("probe")
    local d = rawget(probe, "depth") - 1
    exit(probe, "probe")
    return d
end

-- Run `fn` with `_G.destroyerror` set to `handler` and `io.stderr`
-- replaced by a buffer; returns what was written.
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

local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function read_file(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return data
end

-- Run `source` as a fresh program under the interpreter running this
-- suite, from the repository root; returns its standard output and
-- standard error.
local function run_program(source)
    local interpreter = arg and arg[-1] or "lua5.1"
    local script, out, err = os.tmpname(), os.tmpname(), os.tmpname()
    local f = assert(io.open(script, "wb"))
    f:write("package.path = './?.lua;./?/init.lua;' .. package.path\n", source)
    f:close()
    os.execute(string.format("%s %s >%s 2>%s", shell_quote(interpreter), shell_quote(script), shell_quote(out), shell_quote(err)))
    local stdout, stderr = read_file(out), read_file(err)
    os.remove(script)
    os.remove(out)
    os.remove(err)
    return stdout, stderr
end

------------------------------------------------------------------------
test.suite("sentinel: the implicit term and lifetime.pin")

test.case("attach adds the term unless every anchor is a pinned value; format shows it", function()
    local a = setmetatable({}, {__tostring = function()
        return "a"
    end})
    local b = setmetatable({}, {__tostring = function()
        return "b"
    end})
    local x = attach({}, false, a)
    test.assert_eq(lifetime.format(x), "(a, reachable)")
    attach(x, false, a, b)
    test.assert_eq(lifetime.format(x), "(a, b, reachable)")
    attach(x, false, pin(a))
    test.assert_eq(lifetime.format(x), "a", "a pinned value alone: no term")
    attach(x, false, pin(a), pin(b))
    test.assert_eq(lifetime.format(x), "(a, b)", "pinned values only: no term")
    attach(x, false, pin(a), b)
    test.assert_eq(lifetime.format(x), "(a, b, reachable)", "a table adds the term")
    attach(x, false, pin(a), lifetime.reachable)
    test.assert_eq(lifetime.format(x), "(a, reachable)", "lifetime.reachable adds the term")
    attach(x, false, lifetime.reachable)
    test.assert_eq(lifetime.format(x), "reachable")
end)

test.case("pin(a, b) is a lifetime value without the term; it strips the term of a value it is given", function()
    local a = setmetatable({}, {__tostring = function()
        return "a"
    end})
    local b = setmetatable({}, {__tostring = function()
        return "b"
    end})
    local v = pin(a, b)
    test.assert_eq(getmetatable(v), "lifetime")
    test.assert_eq(lifetime.format(v), "(a, b)")
    test.assert_eq(lifetime.format(pin(a)), "a")
    local x = attach({}, false, a, b)
    test.assert_eq(lifetime.format(lifetime.of(x)), "(a, b, reachable)")
    test.assert_eq(lifetime.format(pin(lifetime.of(x))), "(a, b)", "the term of a value is stripped")
    test.assert_eq(lifetime.format(pin(a, lifetime.reachable)), "a", "lifetime.reachable among anchors is stripped")
    test.assert_true(pin(a, b) == pin(b, a), "== compares structure")
    test.assert_false(pin(a) == lifetime.of(attach({}, false, a)), "the term is part of the structure")
end)

test.case("pin() and pin(lifetime.reachable) raise the spec's errors at the caller", function()
    local err = test.assert_error(function()
        pin()
    end, "bad argument #1 to 'lifetime.pin' (anchor expected, got no value)")
    test.assert_eq(err:sub(1, #THIS_FILE), THIS_FILE)
    err = test.assert_error(function()
        pin(lifetime.reachable)
    end, "attempt to pin an empty lifetime")
    test.assert_eq(err:sub(1, #THIS_FILE), THIS_FILE)
    test.assert_error(function()
        pin(lifetime.reachable, lifetime.reachable)
    end, "attempt to pin an empty lifetime")
end)

test.case("pin checks each argument as an element after @", function()
    test.assert_error(function()
        pin(nil)
    end, "attempt to anchor to a nil value")
    test.assert_error(function()
        pin({}, 5)
    end, "attempt to anchor to a number value")
    local dead = {}
    destroy(dead)
    test.assert_error(function()
        pin(dead)
    end, "attempt to anchor to a dead table")
    test.assert_error(function()
        pin(lifetime.scope)
    end, "attempt to anchor to lifetime.scope through a variable")
end)

test.case("a pinned value is an immutable snapshot: @ on it after an anchor died raises", function()
    local a = setmetatable({}, {__tostring = function()
        return "a"
    end})
    local v = pin(a)
    destroy(a)
    test.assert_eq(lifetime.format(v), "dead a")
    test.assert_error(function()
        attach({}, false, v)
    end, "attempt to anchor to a dead table")
    local tok = token("t")
    local w = pin(tok)
    destroy(tok)
    test.assert_error(function()
        attach({}, false, w)
    end, "attempt to anchor to a dead token")
end)

test.case("case 2: a pinned dependent survives a collection unreferenced and dies with its anchor", function()
    local log = {}
    local a = new_logged(log, "a")
    local probe = setmetatable({}, {__mode = "k"})
    local function make()
        local x = attach(new_logged(log, "x"), false, pin(a))
        probe[x] = true
    end
    run_dropped(make)
    collect()
    collect()
    test.assert_deep_eq(log, {}, "nothing died at the collection")
    test.assert_true(next(probe) ~= nil, "the anchor holds its pinned dependent")
    local x = next(probe)
    test.assert_deep_eq(lifetime.dependents(a), {x})
    destroy(a)
    test.assert_deep_eq(log, {"a (destroy)", "x (anchor)"})
end)

------------------------------------------------------------------------
test.suite("sentinel: which objects carry one")

test.case("a table with the term and a __destroy carries a sentinel; without either it does not", function()
    local a = {}
    local x = attach(new_logged({}, "x"), false, a)
    test.assert_true(sentinel_of(x) ~= nil, "term and __destroy")
    local plain = attach({}, false, a)
    test.assert_eq(sentinel_of(plain), nil, "term, nothing to run at collection")
    local pinned = attach(new_logged({}, "p"), false, pin(a))
    test.assert_eq(sentinel_of(pinned), nil, "a pinned object never carries one")
    local flagged = attach(new_logged({}, "f"), true, a)
    test.assert_eq(sentinel_of(flagged), nil, "nor one attached with the pin flag")
end)

test.case("a table with the term gets one with its first dependent or hook; a pinned anchor does not", function()
    local a = {}
    local anchor = attach({}, false, a)
    test.assert_eq(sentinel_of(anchor), nil)
    local dep = attach({}, false, anchor)
    test.assert_true(sentinel_of(anchor) ~= nil, "dependents to kill at collection")
    test.assert_eq(sentinel_of(dep), nil)
    local hooked = attach({}, false, a)
    hook(function()
    end, nil, hooked)
    test.assert_true(sentinel_of(hooked) ~= nil, "a hook to run at collection")
    local pinned_anchor = attach({}, false, pin(a))
    local dep2 = attach({}, false, pinned_anchor)
    test.assert_eq(sentinel_of(pinned_anchor), nil, "a pinned anchor has no term")
    test.assert_true(dep2 ~= nil and dep ~= nil)
end)

test.case("a hook carries none, unless its formula is lifetime.reachable alone", function()
    local a = {}
    local h = hook(function()
    end, nil, a)
    test.assert_eq(sentinel_of(h), nil)
    local alone = hook(function()
    end, "alone", lifetime.reachable)
    test.assert_true(sentinel_of(alone) ~= nil)
    test.assert_eq(lifetime.format(alone), "hook alone")
    test.assert_eq(lifetime.format(lifetime.of(alone)), "reachable")
    -- Moved onto an anchor it is pinned again and drops the sentinel.
    attach(alone, false, a)
    test.assert_eq(sentinel_of(alone), nil)
    test.assert_eq(lifetime.format(lifetime.of(alone)), tostring(a))
end)

test.case("a token carries one under the same rule as a table", function()
    local owner = {}
    local tok = token("t")
    test.assert_eq(sentinel_of(tok), nil, "a fresh token has nothing to run")
    attach(tok, false, owner)
    test.assert_eq(sentinel_of(tok), nil, "no __destroy, no dependents")
    local dep = attach({}, false, tok)
    test.assert_true(sentinel_of(tok) ~= nil, "a token with the term and a dependent")
    local pinned = attach(token("p"), false, pin(owner))
    attach({}, false, pinned)
    test.assert_eq(sentinel_of(pinned), nil, "a pinned token never")
    test.assert_true(dep ~= nil)
end)

test.case("x @ lifetime.reachable and lifetime.of register a table with a __destroy", function()
    local x = attach(new_logged({}, "x"), false, lifetime.reachable)
    test.assert_true(sentinel_of(x) ~= nil)
    local y = new_logged({}, "y")
    lifetime.of(y)
    test.assert_true(sentinel_of(y) ~= nil)
    local z = new_logged({}, "z")
    test.assert_eq(state_of(z), nil, "never seen: no record, no sentinel")
end)

test.case("never twice: a move that keeps the term keeps the proxy; one that drops it drops it", function()
    local a, b = {}, {}
    local x = attach(new_logged({}, "x"), false, a)
    local p = sentinel_of(x)
    attach(x, false, b)
    test.assert_true(rawequal(sentinel_of(x), p), "same proxy after a move")
    attach(x, false, a, b)
    test.assert_true(rawequal(sentinel_of(x), p), "same proxy after a move to a list")
    attach(x, false, lifetime.reachable)
    test.assert_true(rawequal(sentinel_of(x), p), "same proxy on the default lifetime")
    attach(x, false, pin(a))
    test.assert_eq(sentinel_of(x), nil, "pinned: no proxy")
    attach(x, false, b)
    test.assert_true(sentinel_of(x) ~= nil, "the term again: a sentinel again")
end)

test.case("a scope record carries one only on a coroutine's stack, with its first dependent", function()
    local s = enter("t.lt:1")
    local x = attach(new_logged({}, "x"), false, s)
    test.assert_eq(sentinel_of(s), nil, "the main thread's records are the runtime's roots")
    exit(s, "t.lt:1")
    local seen = {}
    local co = coroutine.create(function()
        local r = enter("t.lt:2")
        seen[1] = sentinel_of(r) ~= nil
        local y = attach({}, false, r)
        seen[2] = sentinel_of(r) ~= nil
        exit(r, "t.lt:2")
        seen[3] = y
    end)
    assert(coroutine.resume(co))
    test.assert_false(seen[1], "no dependent yet")
    test.assert_true(seen[2], "a record with a dependent on a coroutine's stack")
    test.assert_eq(getmetatable(x), "dead")
end)

------------------------------------------------------------------------
test.suite("sentinel: the collector")

test.case("case 1: an unreferenced dependent dies unreachable at the collection; the anchor lives", function()
    local log = {}
    local a = new_logged(log, "a")
    local x = attach(new_logged(log, "x"), false, a)
    test.assert_deep_eq(lifetime.dependents(a), {x})
    x = nil -- luacheck: ignore 311
    collect()
    test.assert_deep_eq(log, {"x (unreachable)"}, "before the statement after the collection")
    test.assert_deep_eq(lifetime.dependents(a), {})
    test.assert_true(alive(a))
    destroy(a)
    test.assert_deep_eq(log, {"x (unreachable)", "a (destroy)"})
end)

test.case("the cascade takes the dependents with reason anchor, at collector, before collectgarbage returns", function()
    -- A dependent holds its anchor strongly, so the test cannot hold one
    -- and drop the other; each body hands its tombstone-to-be to `saved`.
    -- The dependents are pinned (and one is a hook), so they carry no
    -- sentinel of their own and die by the root's walk.
    local log, saved = {}, {}
    local function save(self)
        saved[tostring(self)] = self
    end
    local function make()
        local parent = attach(new_logged(log, "parent", save), false, lifetime.reachable)
        local child = attach(new_logged(log, "child", save), false, pin(parent))
        parent.child = child
        hook(logger(log, "hook"), nil, parent)
    end
    run_dropped(make)
    test.assert_deep_eq(log, {})
    collect()
    test.assert_deep_eq(log, {"parent (unreachable)", "hook (anchor)", "child (anchor)"}, "before collectgarbage returned")
    test.assert_error(function()
        return saved.parent.k
    end, "attempt to index a dead table (parent, died at collector, unreachable)")
    test.assert_error(function()
        return saved.child.k
    end, "attempt to index a dead table (child, died at collector, anchor)")
end)

test.case("case 3: a subtree held only by itself; the newer dependent's sentinel runs first (see the task file)", function()
    -- docs/02-semantics.md, "Reachability is the collector's": "objects are
    -- finalized newest first by creation ..., each taking its whole
    -- subtree in cascade order; an object already destroyed in an earlier
    -- walk is skipped". The child's sentinel is newer than the parent's,
    -- so the child dies first by its own; the parent's walk skips it. The
    -- task's case 3 expects "parent (unreachable), child (anchor)"
    -- instead: recorded under "Spec issues found".
    local log = {}
    local function make()
        local parent = attach(new_logged(log, "parent"), false, lifetime.reachable)
        local child = attach(new_logged(log, "child"), false, parent)
        child.parent = parent
    end
    run_dropped(make)
    collect()
    test.assert_deep_eq(log, {"child (unreachable)", "parent (unreachable)"})
end)

test.case("a dependent with the term and nothing to run carries no sentinel and dies by its anchor's walk", function()
    local log = {}
    local seen = {}
    local function make()
        local parent = attach(new_logged(log, "parent", function(self)
            seen.child = self.child
            seen.alive = alive(self.child)
        end), false, lifetime.reachable)
        local child = attach({}, false, parent)
        test.assert_eq(sentinel_of(child), nil)
        child.parent = parent
        parent.child = child
    end
    run_dropped(make)
    collect()
    test.assert_deep_eq(log, {"parent (unreachable)"})
    test.assert_true(seen.alive, "alive inside the parent's body")
    test.assert_eq(getmetatable(seen.child), "dead", "tombstoned by the walk")
end)

test.case("case 4: two unrelated objects in one collection die newest first", function()
    local log = {}
    -- Both are held until both exist, so that they become unreachable
    -- together, when `make` returns.
    local function make()
        local a = attach(new_logged(log, "a"), false, lifetime.reachable)
        local b = attach(new_logged(log, "b"), false, lifetime.reachable)
        return a ~= b
    end
    run_dropped(make)
    collect()
    test.assert_deep_eq(log, {"b (unreachable)", "a (unreachable)"})
end)

test.case("newest first is the order of the @ that gave each its sentinel", function()
    local log = {}
    local function make()
        local older = new_logged(log, "created first")
        local newer = new_logged(log, "created second")
        attach(newer, false, lifetime.reachable)
        attach(older, false, lifetime.reachable)
    end
    run_dropped(make)
    collect()
    test.assert_deep_eq(log, {"created first (unreachable)", "created second (unreachable)"})
end)

test.case("the older one's walk skips the younger one if it was its dependent", function()
    local log = {}
    local function make()
        local older = attach(new_logged(log, "older"), false, lifetime.reachable)
        local younger = attach(new_logged(log, "younger"), false, older)
        local other = attach(new_logged(log, "other"), false, older)
        older.kids = {younger, other}
    end
    run_dropped(make)
    collect()
    test.assert_deep_eq(log, {"other (unreachable)", "younger (unreachable)", "older (unreachable)"})
end)

test.case("the walk of a newer anchor takes an older dependent; its own finalizer then skips it", function()
    local log = {}
    local function make()
        local older = new_logged(log, "older")
        attach(older, false, lifetime.reachable)
        local anchor = attach(new_logged(log, "anchor"), false, lifetime.reachable)
        attach(older, false, anchor)
        anchor.older = older
    end
    run_dropped(make)
    collect()
    test.assert_deep_eq(log, {"anchor (unreachable)", "older (anchor)"})
end)

test.case("registration: x @ lifetime.reachable runs __destroy at collection; never seen, the table goes silently", function()
    local log = {}
    local function make()
        attach(new_logged(log, "registered"), false, lifetime.reachable)
        local silent = new_logged(log, "silent")
        silent.x = 1
    end
    run_dropped(make)
    collect()
    test.assert_deep_eq(log, {"registered (unreachable)"})
end)

test.case("lifetime.of registers too", function()
    local log = {}
    local function make()
        lifetime.of(new_logged(log, "seen"))
    end
    run_dropped(make)
    collect()
    test.assert_deep_eq(log, {"seen (unreachable)"})
end)

test.case("case 5: a weak table clears one collection after the finalizer", function()
    local log = {}
    local w = setmetatable({}, {__mode = "k"})
    local function make()
        local x = attach(new_logged(log, "x"), false, lifetime.reachable)
        w[x] = true
    end
    run_dropped(make)
    collect()
    test.assert_deep_eq(log, {"x (unreachable)"})
    -- After one collection `next(w)` may still be `x`, now a tombstone:
    -- the finalizer resurrected it for its cascade, and Lua 5.1 clears a
    -- weak entry one cycle after the finalizer (docs/02-semantics.md,
    -- "Host"). Not asserted: "may".
    local k = next(w)
    if k ~= nil then
        test.assert_eq(getmetatable(k), "dead")
    end
    k = nil -- luacheck: ignore 311
    collect()
    test.assert_eq(next(w), nil, "cleared after the second collection")
end)

test.case("case 8: a metatable made in the same statement as its instance still runs", function()
    -- The sentinel's finalizer resurrects the instance and, through it, its
    -- metatable: the opposite of the `xd` inline-metatable trap.
    local log = {}
    local function make()
        attach(setmetatable({}, {
            __destroy = function(_, reason)
                log[#log + 1] = "inline (" .. reason .. ")"
            end
        }), false, lifetime.reachable)
    end
    run_dropped(make)
    collect()
    test.assert_deep_eq(log, {"inline (unreachable)"})
end)

test.case("a disarmed proxy is reused by the next owner, and newest first still holds", function()
    -- The runtime keeps the proxy of an owner that died by a cascade for
    -- the next owner (docs/03-runtime.md, "The sentinel": never twice for
    -- the same object; the order of the finalizers stays the order of the
    -- `@`s). x2 dies below the last slot (a hole), x4 and x3 from the
    -- last slot (kept); the step down over the hole moves the kept
    -- proxies down; y1 and y2 then take x3's and x4's proxies, in order.
    local log = {}
    local proxies = {}
    local function make()
        local x1 = attach(new_logged(log, "x1"), false, lifetime.reachable)
        local x2 = attach(new_logged(log, "x2"), false, lifetime.reachable)
        local x3 = attach(new_logged(log, "x3"), false, lifetime.reachable)
        local x4 = attach(new_logged(log, "x4"), false, lifetime.reachable)
        proxies[3], proxies[4] = sentinel_of(x3), sentinel_of(x4)
        destroy(x2)
        destroy(x4)
        destroy(x3)
        local y1 = attach(new_logged(log, "y1"), false, lifetime.reachable)
        local y2 = attach(new_logged(log, "y2"), false, lifetime.reachable)
        test.assert_true(rawequal(sentinel_of(y1), proxies[3]), "y1 took x3's proxy")
        test.assert_true(rawequal(sentinel_of(y2), proxies[4]), "y2 took x4's proxy")
        -- A proxy's metatable holds its owner: let go of them.
        proxies[3], proxies[4] = nil, nil
        return x1 ~= nil
    end
    run_dropped(make)
    test.assert_deep_eq(log, {"x2 (destroy)", "x4 (destroy)", "x3 (destroy)"})
    collect()
    test.assert_deep_eq(log, {"x2 (destroy)", "x4 (destroy)", "x3 (destroy)", "y2 (unreachable)", "y1 (unreachable)", "x1 (unreachable)"})
end)

test.case("a proxy disarmed below holes is kept as the newest; the kept ones move down over the holes", function()
    -- x3 dies below the last slot (a hole), x4 from the last slot (kept),
    -- then x2, below the hole x3 left: every slot above it is a hole, so
    -- it is the newest armed proxy and is kept, x4's moving down next to
    -- it. y1 and y2 take x2's and x4's proxies, in creation order.
    local log = {}
    local proxies = {}
    local function make()
        local x1 = attach(new_logged(log, "x1"), false, lifetime.reachable)
        local x2 = attach(new_logged(log, "x2"), false, lifetime.reachable)
        local x3 = attach(new_logged(log, "x3"), false, lifetime.reachable)
        local x4 = attach(new_logged(log, "x4"), false, lifetime.reachable)
        proxies[2], proxies[4] = sentinel_of(x2), sentinel_of(x4)
        destroy(x3)
        destroy(x4)
        destroy(x2)
        local y1 = attach(new_logged(log, "y1"), false, lifetime.reachable)
        local y2 = attach(new_logged(log, "y2"), false, lifetime.reachable)
        test.assert_true(rawequal(sentinel_of(y1), proxies[2]), "y1 took x2's proxy")
        test.assert_true(rawequal(sentinel_of(y2), proxies[4]), "y2 took x4's proxy")
        proxies[2], proxies[4] = nil, nil
        return x1 ~= nil
    end
    run_dropped(make)
    collect()
    test.assert_deep_eq(log, {"x3 (destroy)", "x4 (destroy)", "x2 (destroy)", "y2 (unreachable)", "y1 (unreachable)", "x1 (unreachable)"})
end)

test.case("a proxy whose finalizer is pending is not handed to another owner", function()
    -- `q`, a plain proxy made after X's sentinel, is finalized first in
    -- the same collection: its `__gc` destroys X's anchor, so X dies by
    -- that cascade while its own finalizer is pending, and then anchors W.
    -- Had X's proxy been kept, W would take it and X's pending finalizer
    -- would kill W, which the test holds.
    -- W1 and W2 are two new owners, so that one of them would be given
    -- X's slot (A's tombstone gives back A's slot too).
    local log = {}
    local A = new_logged(log, "A")
    local W = {}
    local function make()
        attach(new_logged(log, "X"), false, A)
        local q = newproxy(true)
        getmetatable(q).__gc = function()
            destroy(A)
            W[1] = attach(new_logged(log, "W1"), false, lifetime.reachable)
            W[2] = attach(new_logged(log, "W2"), false, lifetime.reachable)
        end
    end
    run_dropped(make)
    collect()
    test.assert_deep_eq(log, {"A (destroy)", "X (anchor)"})
    collect()
    collect()
    test.assert_deep_eq(log, {"A (destroy)", "X (anchor)"}, "neither W was killed")
    test.assert_true(alive(W[1]) and alive(W[2]))
end)

test.case("an object already dead is skipped by its finalizer; its sentinel is disarmed", function()
    local log = {}
    local function make()
        local x = attach(new_logged(log, "x"), false, lifetime.reachable)
        local p = sentinel_of(x)
        destroy(x)
        test.assert_eq(rawget(getmetatable(p), "owner"), nil, "disarmed")
        test.assert_eq(sentinel_of(x), nil)
    end
    run_dropped(make)
    test.assert_deep_eq(log, {"x (destroy)"})
    collect()
    collect()
    test.assert_deep_eq(log, {"x (destroy)"})
end)

test.case("a dependent killed by its anchor's cascade is not run again by its own finalizer", function()
    local log = {}
    local a = new_logged(log, "a")
    local x = attach(new_logged(log, "x"), false, a)
    test.assert_true(sentinel_of(x) ~= nil)
    destroy(a)
    test.assert_deep_eq(log, {"a (destroy)", "x (anchor)"})
    x = nil -- luacheck: ignore 311
    collect()
    collect()
    test.assert_deep_eq(log, {"a (destroy)", "x (anchor)"})
end)

test.case("a hook anchored to lifetime.reachable alone runs with unreachable when collected", function()
    local log = {}
    local held = hook(logger(log, "held"), nil, lifetime.reachable)
    local function make()
        hook(logger(log, "dropped"), nil, lifetime.reachable)
    end
    run_dropped(make)
    collect()
    test.assert_deep_eq(log, {"dropped (unreachable)"})
    test.assert_true(alive(held))
    destroy(held)
    test.assert_deep_eq(log, {"dropped (unreachable)", "held (destroy)"})
end)

test.case("an unreferenced token's cascade kills its dependents with reason anchor", function()
    -- `menu` is pinned, so it carries no sentinel of its own and the
    -- token's walk takes it; it holds the token, so the test cannot hold
    -- it, and its body hands it to `saved`.
    local log = {}
    local saved
    local function make()
        local period = token("period")
        local menu = attach(new_logged(log, "menu", function(self)
            saved = self
        end), false, pin(period))
        hook(logger(log, "hook"), nil, period)
        test.assert_true(sentinel_of(period) ~= nil)
        return menu ~= nil
    end
    run_dropped(make)
    collect()
    test.assert_deep_eq(log, {"hook (anchor)", "menu (anchor)"})
    test.assert_eq(getmetatable(saved), "dead")
end)

test.case("errors of a finalizer-run cascade all go to destroyerror, the first included", function()
    local log, routed = {}, {}
    local ok
    local function make()
        local x = attach(new_logged(log, "x", function()
            error("x failed", 0)
        end), false, lifetime.reachable)
        local y = attach(new_logged(log, "y", function()
            error("y failed", 0)
        end), false, pin(x))
        return y ~= nil
    end
    with_handler(function(obj, e)
        routed[#routed + 1] = {tostring(obj), e}
    end, function()
        run_dropped(make)
        -- Called directly, as the other cases do: a `pcall` here would put
        -- its frame where `make`'s was and leave a stale slot holding `x`
        -- on LuaJIT. An error escaping the collection would fail the case.
        collect()
        ok = true
    end)
    test.assert_true(ok, "collectgarbage does not raise")
    test.assert_deep_eq(log, {"x (unreachable)", "y (anchor)"})
    test.assert_deep_eq(routed, {{"x", "x failed"}, {"y", "y failed"}})
end)

test.case("a finalizer that runs inside attach waits until attach has linked, then runs", function()
    -- docs/02-semantics.md, "Reachability is the collector's": a
    -- destructor run by the collector runs at an arbitrary allocation
    -- point. A line hook collects at the first line `attach` runs with its
    -- operation open (its upvalue `busy` above 0), after it has validated
    -- the anchor `a`: the finalizer of `U`, whose body destroys `a`, must
    -- not leave `obj` linked to a tombstone. It runs when `attach` is
    -- done, and its cascade takes `obj` with `a`.
    --
    -- `U` is held in `holder` until just before the call and dropped by a
    -- table store while the collector is stopped: no collection can find
    -- it before `attach` runs, however eager the collector.
    local log = {}
    local a = new_logged(log, "a")
    local holder = {}
    local function make()
        holder[1] = attach(new_logged(log, "U", function()
            destroy(a)
        end), false, lifetime.reachable)
    end
    run_dropped(make)
    test.assert_true(sentinel_of(holder[1]) ~= nil, "U is registered and held")
    local busy_index
    for i = 1, math.huge do
        local name = debug.getupvalue(attach, i)
        if name == nil then
            break
        elseif name == "busy" then
            busy_index = i
        end
    end
    test.assert_true(busy_index ~= nil, "attach has the upvalue busy")
    local obj = new_logged(log, "obj")
    local fired = false
    local during
    local jit_on = rawget(_G, "jit") and jit.status()
    if jit_on then
        jit.off()
        jit.flush()
    end
    local function on_line()
        if not fired and select(2, debug.getupvalue(attach, busy_index)) > 0 then
            fired = true
            collect()
            during = #log
        end
    end
    -- The hook allocates (`debug.getupvalue` pushes a string), so the
    -- automatic collector is stopped until the hook's own full collection.
    collectgarbage("stop")
    holder[1] = nil
    debug.sethook(on_line, "l")
    attach(obj, false, a)
    debug.sethook()
    collectgarbage("restart")
    if jit_on then
        jit.on()
    end
    test.assert_true(fired, "the collection ran inside attach")
    test.assert_eq(during, 0, "the finalizer waited")
    test.assert_deep_eq(log, {"U (unreachable)", "a (destroy)", "obj (anchor)"})
    test.assert_eq(getmetatable(obj), "dead")
end)

test.case("a foreign __gc that raises inside attach does not stop later deaths by the collector", function()
    -- Task 004, review round 1, F2. A plain proxy whose `__gc` raises is
    -- collected inside `attach`, while the runtime's flag `busy` is set;
    -- on Lua 5.1 the error leaves `attach` through the allocation, before
    -- the flag is cleared. The next operation sets and clears the flag
    -- again, so a later registered object still dies at the next
    -- collection. Only the recovery is asserted: whether the error
    -- reaches `attach` depends on the host. LuaJIT does not propagate an
    -- error from a finalizer; it writes "ERROR in finalizer" to stderr
    -- itself, so there the `__gc` does not raise, to keep the suite's
    -- output clean, and the case checks the same recovery.
    local raises = not rawget(_G, "jit")
    local busy_index
    for i = 1, math.huge do
        local name = debug.getupvalue(attach, i)
        if name == nil then
            break
        elseif name == "busy" then
            busy_index = i
        end
    end
    test.assert_true(busy_index ~= nil, "attach has the upvalue busy")
    local anchor = {}
    local fired = false
    local function on_line()
        if not fired and select(2, debug.getupvalue(attach, busy_index)) ~= 0 then
            fired = true
            collect()
        end
    end
    local jit_on = rawget(_G, "jit") and jit.status()
    if jit_on then
        jit.off()
        jit.flush()
    end
    collectgarbage("stop")
    run_dropped(function()
        local q = newproxy(true)
        getmetatable(q).__gc = function()
            if raises then
                error("foreign __gc", 0)
            end
        end
    end)
    debug.sethook(on_line, "l")
    pcall(attach, {}, false, anchor)
    debug.sethook()
    collectgarbage("restart")
    if jit_on then
        jit.on()
    end
    test.assert_true(fired, "the collection ran inside attach")
    local log = {}
    run_dropped(function()
        attach(new_logged(log, "later"), false, lifetime.reachable)
    end)
    collect()
    test.assert_deep_eq(log, {"later (unreachable)"})
end)

------------------------------------------------------------------------
test.suite("sentinel: program end")

test.case("the exit flag turns the reason of the finalizers at state close into exit", function()
    local stdout, stderr = run_program([[
local lifetime = require("lifetime")
local function logged(name)
    return setmetatable({}, {__destroy = function(_, reason) print(name .. " (" .. reason .. ")") end})
end
g = lifetime.attach(logged("g"), false, lifetime.reachable)
local function make() lifetime.attach(logged("tmp"), false, lifetime.reachable) end
make()
collectgarbage("collect")
print("collected")
lifetime.set_exiting(true)
]])
    test.assert_eq(stderr, "")
    test.assert_eq(stdout, "tmp (unreachable)\ncollected\ng (exit)\n")
end)

test.case("without the flag a finalizer at state close reports unreachable", function()
    local stdout, stderr = run_program([[
local lifetime = require("lifetime")
g = lifetime.attach(setmetatable({}, {__destroy = function(_, reason) print("g (" .. reason .. ")") end}), false, lifetime.reachable)
]])
    test.assert_eq(stderr, "")
    test.assert_eq(stdout, "g (unreachable)\n")
end)

------------------------------------------------------------------------
test.suite("sentinel: tokens")

test.case("lifetime.token: metatable token, tostring with and without a name, the name must be a string", function()
    local t = token("period")
    test.assert_eq(getmetatable(t), "token")
    test.assert_eq(tostring(t), "token period")
    test.assert_eq(lifetime.format(t), "token period")
    local anon = token()
    test.assert_true(tostring(anon):match("^token: 0x%x+$") ~= nil or tostring(anon):match("^token: %x+$") ~= nil, tostring(anon))
    test.assert_eq(lifetime.format(anon), tostring(anon))
    local err = test.assert_error(function()
        token(5)
    end, "bad argument #1 to 'lifetime.token' (string expected, got number)")
    test.assert_eq(err:sub(1, #THIS_FILE), THIS_FILE)
    test.assert_error(function()
        token(true)
    end, "bad argument #1 to 'lifetime.token' (string expected, got boolean)")
    test.assert_true(token("a") ~= token("a"), "each token is fresh")
end)

test.case("a token has no fields: indexing or assigning raises attempt to index a token value", function()
    local t = token("t")
    test.assert_error(function()
        return t.x
    end, "attempt to index a token value")
    test.assert_error(function()
        t.x = 1
    end, "attempt to index a token value")
    test.assert_error(function()
        setmetatable(t, {})
    end, "cannot change a protected metatable")
end)

test.case("a token starts on the default lifetime and is seen; it is an anchor and a dependent", function()
    local owner = setmetatable({}, {__tostring = function()
        return "owner"
    end})
    local t = token("t")
    test.assert_true(rawequal(lifetime.of(t), lifetime.reachable))
    test.assert_true(state_of(t) ~= nil, "created by lifetime.token: seen")
    test.assert_true(rawequal(attach(t, false, owner), t))
    test.assert_eq(lifetime.format(lifetime.of(t)), "(owner, reachable)")
    local x = attach({}, false, t)
    test.assert_eq(lifetime.format(x), "(token t, reachable)")
    test.assert_deep_eq(lifetime.dependents(owner), {t})
    test.assert_deep_eq(lifetime.dependents(t), {x})
end)

test.case("case 6: a token's period: destroy(period) runs hook then menu; destroy(session) then omits period", function()
    local log = {}
    local session = new_logged(log, "session")
    local period = attach(token("period"), false, session)
    local menu = attach(new_logged(log, "menu"), false, period)
    hook(logger(log, "hook"), nil, period)
    test.assert_deep_eq(log, {})
    local where = THIS_FILE .. ":" .. debug.getinfo(1, "l").currentline + 1
    destroy(period)
    test.assert_deep_eq(log, {"hook (anchor)", "menu (anchor)"})
    test.assert_false(alive(period))
    test.assert_eq(getmetatable(period), "dead")
    test.assert_eq(tostring(period), "dead token period")
    test.assert_error(function()
        return menu.x
    end, "attempt to index a dead table (menu, died at " .. where .. ", anchor)")
    test.assert_deep_eq(lifetime.dependents(session), {})
    destroy(session)
    test.assert_deep_eq(log, {"hook (anchor)", "menu (anchor)", "session (destroy)"})
end)

test.case("a dead token names itself in the tombstone message and refuses anchoring as a token", function()
    local t = token("period")
    local where = THIS_FILE .. ":" .. debug.getinfo(1, "l").currentline + 1
    destroy(t)
    test.assert_error(function()
        return t.x
    end, "attempt to index a dead table (token period, died at " .. where .. ", destroy)")
    test.assert_error(function()
        attach({}, false, t)
    end, "attempt to anchor to a dead token")
    test.assert_error(function()
        attach(t, false, {})
    end, "attempt to index a dead table (token period")
end)

test.case("a token can be moved, pinned and discarded", function()
    local log = {}
    local a, b = {}, {}
    local t = attach(token("t"), false, pin(a))
    hook(logger(log, "h"), nil, t)
    attach(t, false, pin(b))
    test.assert_deep_eq(lifetime.dependents(a), {})
    test.assert_deep_eq(lifetime.dependents(b), {t})
    discard(t)
    test.assert_deep_eq(log, {"h (anchor)"})
    test.assert_false(alive(t))
end)

------------------------------------------------------------------------
test.suite("sentinel: lifetime.alive")

test.case("case 7: alive is true before, true inside __destroy, false after", function()
    local inside
    local x = setmetatable({}, {
        __destroy = function(self)
            inside = alive(self)
        end
    })
    test.assert_true(alive(x))
    destroy(x)
    test.assert_true(inside, "a dying object is alive")
    test.assert_false(alive(x))
end)

test.case("alive: nil and false are false; a value raises; other objects are alive", function()
    test.assert_false(alive(nil))
    test.assert_false(alive(false))
    local err = test.assert_error(function()
        alive(5)
    end, "bad argument #1 to 'lifetime.alive' (object expected, got number)")
    test.assert_eq(err:sub(1, #THIS_FILE), THIS_FILE)
    test.assert_error(function()
        alive("s")
    end, "bad argument #1 to 'lifetime.alive' (object expected, got string)")
    test.assert_error(function()
        alive(true)
    end, "bad argument #1 to 'lifetime.alive' (object expected, got boolean)")
    test.assert_true(alive({}), "a table the runtime never saw")
    test.assert_true(alive(print))
    test.assert_true(alive(coroutine.create(function()
    end)))
    test.assert_true(alive(newproxy()))
    test.assert_true(alive(token()))
end)

test.case("alive of hooks, dependents of a cascade and scope dependents", function()
    local log = {}
    local a = {}
    local h = hook(logger(log, "h"), nil, a)
    local seen = {}
    local dep = attach(new_logged(log, "dep", function(self)
        seen[1] = alive(self)
        seen[2] = alive(a)
    end), false, a)
    test.assert_true(alive(h))
    destroy(a)
    test.assert_deep_eq(seen, {true, true}, "dying, inside the cascade")
    test.assert_false(alive(h))
    test.assert_false(alive(dep))
    local s = enter("t.lt:1")
    local x = attach({}, false, s)
    test.assert_true(alive(x))
    exit(s, "t.lt:1")
    test.assert_false(alive(x))
end)

------------------------------------------------------------------------
test.suite("sentinel: coroutines (task 003's follow-ups)")

test.case("task 003 case 7: a collected suspended coroutine's records die through their sentinels", function()
    local log = {}
    local probe = setmetatable({}, {__mode = "k"})
    local function start()
        local co = coroutine.create(function()
            -- `local x = … @ lifetime.scope`: the suspended frame holds x.
            local s = enter("t.lt:10")
            local x = attach(new_logged(log, "x"), false, s)
            coroutine.yield()
            exit(s, "t.lt:10")
            return x
        end)
        coroutine.resume(co)
        probe[co] = true
    end
    start()
    test.assert_deep_eq(log, {}, "suspended: alive")
    collect()
    collect()
    test.assert_deep_eq(log, {"x (unreachable)"})
    collect()
    test.assert_eq(next(probe), nil, "the coroutine was collected")
end)

test.case("a collected coroutine's records die innermost first, whichever sentinel runs first", function()
    local log = {}
    local function start(outer_first)
        local co = coroutine.create(function()
            local s1 = enter("t.lt:20")
            local s2 = enter("t.lt:19")
            -- The order of the first links decides which record's sentinel
            -- is newer, and so which finalizer runs first.
            if outer_first then
                hook(logger(log, "h1"), nil, s1)
                hook(logger(log, "h2"), nil, s2)
            else
                hook(logger(log, "h2"), nil, s2)
                hook(logger(log, "h1"), nil, s1)
            end
            coroutine.yield()
            exit(s2, "t.lt:19")
            exit(s1, "t.lt:20")
        end)
        coroutine.resume(co)
    end
    start(true)
    collect()
    collect()
    test.assert_deep_eq(log, {"h2 (anchor)", "h1 (anchor)"})
    log[1], log[2] = nil, nil
    start(false)
    collect()
    collect()
    test.assert_deep_eq(log, {"h2 (anchor)", "h1 (anchor)"})
end)

test.case("F2: nested coroutines swap stacks; B's record dies inside A's resume, A's at its exit, main's at its", function()
    local log = {}
    local depths = {}
    local before = depth()
    local m = enter("t.lt:40")
    local m1 = attach(new_logged(log, "m1"), false, m)
    local A = coroutine.create(function()
        local a = enter("t.lt:39")
        local a1 = attach(new_logged(log, "a1"), false, a)
        depths.a = depth()
        local B = coroutine.create(function()
            local b = enter("t.lt:38")
            local b1 = attach(new_logged(log, "b1"), false, b)
            depths.b = depth()
            coroutine.yield("b yielded")
            depths.b_resumed = depth()
            log[#log + 1] = "b raises"
            error(b1 and "b failed", 0)
        end)
        local ok, v = coroutine.resume(B)
        log[#log + 1] = "A got " .. tostring(ok) .. " " .. tostring(v)
        depths.a_after_b = depth()
        coroutine.yield("a yielded")
        depths.a_resumed = depth()
        ok, v = coroutine.resume(B)
        log[#log + 1] = "A got " .. tostring(ok) .. " " .. tostring(v)
        depths.a_after_b2 = depth()
        exit(a, "t.lt:39")
        log[#log + 1] = "A exited"
        return a1
    end)
    local ok, v = coroutine.resume(A)
    test.assert_true(ok)
    test.assert_eq(v, "a yielded")
    test.assert_deep_eq(log, {"A got true b yielded"})
    test.assert_eq(depth(), before + 1, "main's stack: m only")
    test.assert_true(alive(m1))
    ok = coroutine.resume(A)
    test.assert_true(ok)
    test.assert_deep_eq(log, {"A got true b yielded", "b raises", "b1 (anchor)", "A got false b failed", "a1 (anchor)", "A exited"})
    test.assert_deep_eq(depths, {a = 1, b = 1, a_after_b = 1, b_resumed = 1, a_resumed = 1, a_after_b2 = 1})
    test.assert_true(alive(m1))
    exit(m, "t.lt:40")
    test.assert_deep_eq(log, {"A got true b yielded", "b raises", "b1 (anchor)", "A got false b failed", "a1 (anchor)", "A exited", "m1 (anchor)"})
    test.assert_eq(depth(), before)
end)

test.case("F1: exit(nil) raises before it pops, on an empty stack and on a non-empty one", function()
    local results = {}
    local co = coroutine.create(function()
        results.before = depth()
        results.ok1 = pcall(exit, nil, "t.lt:50")
        results.after1 = depth()
        local s = enter("t.lt:51")
        results.ok2 = pcall(exit, nil, "t.lt:51")
        results.after2 = depth()
        exit(s, "t.lt:51")
        results.after3 = depth()
    end)
    assert(coroutine.resume(co))
    test.assert_deep_eq(results, {before = 0, ok1 = false, after1 = 0, ok2 = false, after2 = 1, after3 = 0})
end)

return test
