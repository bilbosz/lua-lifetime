-- bench/bench-scopes.lua: the hot paths of task 003 (docs/03-runtime.md,
-- "Performance"): a block with a scope record ("one record (a small
-- table) per entry, one push and one pop; no closure, no `pcall`"), the
-- four replaced globals ("one wrapper frame, one field read before and
-- one compare after; no allocation"), and hook creation. Each body is
-- written as the generated code of docs/04-transpiler.md will be: the
-- runtime functions bound to locals, the record in a local, `enter` with
-- the line of the block's end and `exit` with the line of the exit.
--
--   scope/loop-one-object   a loop body owning one object with a
--                           `__destroy` (`local x = {} @ lifetime.scope`):
--                           enter, attach, exit; against creating the
--                           object and calling its body by hand at the end
--                           of the iteration
--   scope/enter-exit-empty  enter and exit of a record nothing is attached
--                           to; against an empty block (the absolute cost
--                           of a record: the ratio has no meaning beyond
--                           "how many empty blocks")
--   scope/hook-on-scope     a block with one hook (`f !@ lifetime.scope`):
--                           enter, hook, exit; against calling `f` by hand
--                           at the end of the block
--   scope/pcall-empty       pcall of an empty function through the
--                           runtime's pcall; against the original pcall
--   scope/pcall-error       pcall of a function that raises through no
--                           scoped block; against the original pcall
--   scope/resume-yield      one resume of a coroutine that yields in a
--                           loop, through the runtime's coroutine.resume;
--                           against the original
--
-- The baselines of the last three are the originals the runtime keeps as
-- upvalues of its replacements (`pcall`, `resume`); on a base without the
-- replacements the global is the original and both sides run it.
local bench = require("bench.lib.bench")
local lifetime = require("lifetime")

-- The original of a replaced global, or the global itself where the
-- runtime does not replace it (a base before task 003).
local function original(replacement, name)
    if type(replacement) ~= "function" then
        return replacement
    end
    local i = 1
    while true do
        local n, v = debug.getupvalue(replacement, i)
        if n == nil then
            return replacement
        end
        if n == name then
            return v
        end
        i = i + 1
    end
end

local closed = 0
local function body(self, reason)
    closed = closed + 1
end
local MT = {__destroy = body}

-- scope/loop-one-object: `for … do local x = {} @ lifetime.scope … end`.
bench.add("scope/loop-one-object", (function()
    local enter, exit, attach = lifetime.enter, lifetime.exit, lifetime.attach
    return function()
        for _ = 1, 10 do
            local s = enter("bench:1")
            local x = attach(setmetatable({}, MT), false, s)
            x.v = 1
            exit(s, "bench:1")
        end
    end
end)(), {
    baseline = function()
        for _ = 1, 10 do
            local x = setmetatable({}, MT)
            x.v = 1
            body(x, "anchor")
        end
    end
})

-- scope/enter-exit-empty
bench.add("scope/enter-exit-empty", (function()
    local enter, exit = lifetime.enter, lifetime.exit
    return function()
        for _ = 1, 10 do
            local s = enter("bench:2")
            exit(s, "bench:2")
        end
    end
end)(), {
    baseline = function()
        for _ = 1, 10 do
            local _ = closed
        end
    end
})

-- scope/hook-on-scope: `do function() … end !@ lifetime.scope … end`.
local function on_exit(reason)
    closed = closed + 1
end
bench.add("scope/hook-on-scope", (function()
    local enter, exit, hook = lifetime.enter, lifetime.exit, lifetime.hook
    return function()
        for _ = 1, 10 do
            local s = enter("bench:3")
            hook(on_exit, nil, s)
            exit(s, "bench:3")
        end
    end
end)(), {
    baseline = function()
        for _ = 1, 10 do
            on_exit("anchor")
        end
    end
})

local function empty()
end

-- scope/pcall-empty
local original_pcall = original(pcall, "pcall")
bench.add("scope/pcall-empty", function()
    for _ = 1, 10 do
        pcall(empty)
    end
end, {
    baseline = function()
        for _ = 1, 10 do
            original_pcall(empty)
        end
    end
})

-- scope/pcall-error
local ERROR = {}
local function raise()
    error(ERROR)
end
bench.add("scope/pcall-error", function()
    for _ = 1, 10 do
        pcall(raise)
    end
end, {
    baseline = function()
        for _ = 1, 10 do
            original_pcall(raise)
        end
    end
})

-- scope/resume-yield
local original_resume = original(coroutine.resume, "resume")
local function yielder()
    while true do
        coroutine.yield(1)
    end
end
local co_wrapped, co_original = coroutine.create(yielder), coroutine.create(yielder)
bench.add("scope/resume-yield", function()
    local resume = coroutine.resume
    for _ = 1, 10 do
        resume(co_wrapped)
    end
end, {
    baseline = function()
        for _ = 1, 10 do
            original_resume(co_original)
        end
    end
})
