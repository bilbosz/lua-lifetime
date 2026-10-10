-- bench/bench-runtime.lua: the runtime's hot paths of task 002
-- (docs/03-runtime.md, "Performance", the "Cheap" table): `x @ a` the
-- first time, `x @ b` as a move, a cascade over `n` objects, and
-- `lifetime.dependents(a)`. Each baseline is plain Lua doing the same
-- work by hand: an owner keeping its children in an array and closing
-- them with an explicit loop, newest first, calling the same body the
-- runtime calls as `__destroy`.
--
--   runtime/attach-destroy-100  an anchor, 100 dependents attached, then
--                               lifetime.destroy(anchor); against an array of 100
--                               children and a close loop
--   runtime/move                one move of an object between two anchors;
--                               against moving it between two sets
--   runtime/cascade-tree        a three-level tree (1 + 10 + 100) built
--                               with attach and destroyed from the root;
--                               against the same tree of arrays closed by
--                               a recursive loop
--   runtime/dependents-100      lifetime.dependents of an anchor with 100
--                               dependents; against copying an array of 100
--   runtime/attach-first        attach of a fresh table to a long-lived
--                               anchor, the table dropped at once (the
--                               anchor's list collects holes and compacts);
--                               against storing it in a weak-valued array
--   runtime/attach-function     attach of a fresh function to a long-lived
--                               anchor, then lifetime.destroy(function) (task 012:
--                               its record in the weak-keyed side table,
--                               its death remembered there); against
--                               appending it to an array, removing it and
--                               marking it in a weak-keyed set
--
-- The runtime is required lazily inside the benchmarks, so that a base
-- without these functions reports each benchmark as one it cannot run.
local bench = require("bench.lib.bench")
local lifetime = require("lifetime")

local N = 100

local closed = 0
local function body(self, reason)
    closed = closed + 1
end
local CHILD_MT = {__destroy = body}

-- runtime/attach-destroy-100. The children are held, as the baseline's
-- array holds them: a dependent with the `reachable` term that nothing
-- refers to may be found by the collector first (CLAUDE.md, rule 6; task
-- 004 gives it a sentinel, so it would then die "unreachable" mid-loop).
bench.add("runtime/attach-destroy-100", function()
    local attach = lifetime.attach
    local anchor, children = {}, {}
    for i = 1, N do
        children[i] = attach(setmetatable({}, CHILD_MT), false, anchor)
    end
    lifetime.destroy(anchor)
    return children
end, {
    baseline = function()
        local children = {}
        for i = 1, N do
            children[i] = setmetatable({}, CHILD_MT)
        end
        for i = N, 1, -1 do
            body(children[i], "anchor")
            children[i] = nil
        end
    end
})

-- runtime/move
local move_x, move_a, move_b, move_on_a
bench.add("runtime/move", function()
    if not move_x then
        move_a, move_b = {}, {}
        move_x = lifetime.attach({}, false, move_a)
        move_on_a = true
        -- Neighbours, so the move is not into an empty list.
        for _ = 1, 10 do
            lifetime.attach({}, false, move_a)
            lifetime.attach({}, false, move_b)
        end
    end
    if move_on_a then
        lifetime.attach(move_x, false, move_b)
    else
        lifetime.attach(move_x, false, move_a)
    end
    move_on_a = not move_on_a
end, {
    baseline = (function()
        local x, a, b, on_a = {}, {}, {}, true
        a[x] = true
        return function()
            if on_a then
                a[x] = nil
                b[x] = true
            else
                b[x] = nil
                a[x] = true
            end
            on_a = not on_a
            return a, b
        end
    end)()
})

-- runtime/cascade-tree. The tree is held, as the baseline's arrays hold
-- it (see runtime/attach-destroy-100).
bench.add("runtime/cascade-tree", function()
    local attach = lifetime.attach
    local root = setmetatable({}, CHILD_MT)
    local held, n = {}, 0
    for _ = 1, 10 do
        local child = attach(setmetatable({}, CHILD_MT), false, root)
        n = n + 1
        held[n] = child
        for _ = 1, 10 do
            n = n + 1
            held[n] = attach(setmetatable({}, CHILD_MT), false, child)
        end
    end
    lifetime.destroy(root)
    return held
end, {
    baseline = (function()
        local function close(node)
            body(node, "anchor")
            local children = node.children
            for i = #children, 1, -1 do
                close(children[i])
                children[i] = nil
            end
        end
        return function()
            local root = setmetatable({children = {}}, CHILD_MT)
            for i = 1, 10 do
                local child = setmetatable({children = {}}, CHILD_MT)
                root.children[i] = child
                for j = 1, 10 do
                    child.children[j] = setmetatable({children = {}}, CHILD_MT)
                end
            end
            close(root)
        end
    end)()
})

-- runtime/dependents-100
local dependents_anchor, dependents_kept
bench.add("runtime/dependents-100", function()
    if not dependents_anchor then
        dependents_anchor, dependents_kept = {}, {}
        for i = 1, N do
            dependents_kept[i] = lifetime.attach({}, false, dependents_anchor)
        end
    end
    -- dependents_kept holds the dependents: the anchor's list does not.
    return lifetime.dependents(dependents_anchor), dependents_kept
end, {
    baseline = (function()
        local children = {}
        for i = 1, N do
            children[i] = {}
        end
        return function()
            local result = {}
            for i = 1, N do
                result[i] = children[i]
            end
            return result
        end
    end)()
})

-- runtime/attach-first
local first_anchor = {}
bench.add("runtime/attach-first", function()
    lifetime.attach({}, false, first_anchor)
end, {
    baseline = (function()
        local list, n = setmetatable({}, {__mode = "v"}), 0
        return function()
            n = n + 1
            list[n] = {owner = first_anchor}
        end
    end)()
})

-- runtime/attach-function. A base whose runtime refuses a function
-- dependent (before task 012) reports it as a benchmark it cannot run.
local function_anchor = {}
bench.add("runtime/attach-function", function()
    local f = function()
    end
    lifetime.attach(f, false, function_anchor)
    lifetime.destroy(f)
end, {
    baseline = (function()
        local list, n, dead = {}, 0, setmetatable({}, {__mode = "k"})
        return function()
            local f = function()
            end
            n = n + 1
            list[n] = f
            list[n] = nil
            n = n - 1
            dead[f] = true
            return list
        end
    end)()
})
