-- bench/bench-sentinel.lua: the hot paths of task 004 (docs/03-runtime.md,
-- "Performance", "Forced, and measured": "the sentinel, one
-- `newproxy(true)` per table that has the `reachable` term and something
-- to run at collection"), and `lifetime.alive`.
--
--   sentinel/anchor-100   100 objects with a `__destroy` anchored with the
--                         implicit `reachable` term (each needs a
--                         sentinel), then lifetime.destroy(anchor); against the
--                         same 100 objects attached pinned (`attach`'s pin
--                         flag, as `@ lifetime.pin(a)` is: no proxy)
--   sentinel/collect-100  100 objects with a `__destroy` registered with
--                         `@ lifetime.reachable`, dropped, then one
--                         collectgarbage("collect") that runs their 100
--                         cascades from the sentinels' finalizers; against
--                         the same 100 objects never seen, dropped and
--                         collected silently
--   sentinel/alive-10     10 `lifetime.alive` checks of a live object the
--                         runtime has seen; against 10 `x ~= nil` checks
--   sentinel/register-tree  a tree of three levels, 10 children per node
--                         (1 + 10 + 100 objects with a `__destroy`), every
--                         object registered with `@ lifetime.reachable` at
--                         construction and then linked `child @ parent`,
--                         top down, then lifetime.destroy(root); against
--                         the same tree linked without prior registration.
--                         The ratio is what registering costs the tree,
--                         the exchanges of "Anchors first" included (task
--                         017, docs/03-runtime.md, "The sentinel"): each
--                         registered child's proxy is newer than its
--                         ancestors', so its link climbs to the root. On a
--                         base before task 017 nothing is exchanged.
--
-- The objects of `sentinel/anchor-100` are held by the benchmark, as the
-- baseline's are by their anchor: a dependent with the term that nothing
-- refers to may be found by the collector first (CLAUDE.md, rule 6).
--
-- On a base before task 004 the first is the runtime without sentinels on
-- both sides, and the others cannot run (no `lifetime.alive`; no
-- finalizer, so the "collect" benchmark measures nothing there).
local bench = require("bench.lib.bench")
local lifetime = require("lifetime")

local N = 100

local closed = 0
local function body(self, reason)
    closed = closed + 1
end
local MT = {__destroy = body}

-- sentinel/anchor-100
local function anchor_n(pin)
    local attach = lifetime.attach
    local anchor, objects = {}, {}
    for i = 1, N do
        objects[i] = attach(setmetatable({}, MT), pin, anchor)
    end
    lifetime.destroy(anchor)
    return objects
end

bench.add("sentinel/anchor-100", function()
    return anchor_n(false)
end, {
    baseline = function()
        return anchor_n(true)
    end
})

-- sentinel/collect-100
local function make_registered()
    local attach, reachable = lifetime.attach, lifetime.reachable
    if not lifetime.alive then
        error("no sentinel in this runtime")
    end
    for _ = 1, N do
        attach(setmetatable({}, MT), false, reachable)
    end
end

local function make_unseen()
    local keep
    for _ = 1, N do
        keep = setmetatable({}, MT)
    end
    return keep ~= nil
end

bench.add("sentinel/collect-100", function()
    make_registered()
    collectgarbage("collect")
end, {
    baseline = function()
        make_unseen()
        collectgarbage("collect")
    end
})

-- sentinel/alive-10. Each returns its count, so the checks are not dead
-- code.
local seen = lifetime.attach({}, false, lifetime.reachable)
bench.add("sentinel/alive-10", function()
    local alive = lifetime.alive
    local n = 0
    for _ = 1, 10 do
        if alive(seen) then
            n = n + 1
        end
    end
    return n
end, {
    baseline = function()
        local n = 0
        for _ = 1, 10 do
            if seen ~= nil then
                n = n + 1
            end
        end
        return n
    end
})

-- sentinel/register-tree. The tree is held by the benchmark until the
-- destroy, as the baseline's is (CLAUDE.md, rule 6).
local function tree(register)
    local attach, reachable = lifetime.attach, lifetime.reachable
    local function make()
        local obj = setmetatable({}, MT)
        if register then
            attach(obj, false, reachable)
        end
        return obj
    end
    local root = make()
    local held, n = {}, 0
    for _ = 1, 10 do
        local child = attach(make(), false, root)
        n = n + 1
        held[n] = child
        for _ = 1, 10 do
            n = n + 1
            held[n] = attach(make(), false, child)
        end
    end
    lifetime.destroy(root)
    return held
end

bench.add("sentinel/register-tree", function()
    return tree(true)
end, {
    baseline = function()
        return tree(false)
    end
})
