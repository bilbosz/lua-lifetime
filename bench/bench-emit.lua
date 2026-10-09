-- bench/bench-emit.lua: what the emitter writes (task 006;
-- docs/04-transpiler.md, "Blocks", "Functions"; docs/03-runtime.md,
-- "Performance"). Each benchmark runs code built by `cli.build` from a
-- `.lt` source; the baseline is plain Lua doing the same work by hand,
-- loaded with `loadstring`. One operation is ten iterations or calls.
--
--   emit/scoped-loop     a loop body owning one object with a `__destroy`
--                        (`local x = setmetatable({}, MT) @
--                        lifetime.scope`): record, push, attach, pop and
--                        epilogue per iteration; against calling the
--                        destructor by hand at the end of each iteration
--   emit/unscoped-loop   the same loop with no scoped object, in a chunk
--                        whose other function has a scope record; against
--                        the same loop loaded directly: the ratio must be
--                        1.0 ("a block with no `@ lifetime.scope` ... gets
--                        no scope record, no push and no pop")
--   emit/calls           65 calls of two small functions, in a chunk with
--                        a scope record elsewhere; against the
--                        same function loaded directly: the ratio must be
--                        1.0 ("no generated function has a prologue or an
--                        epilogue of its own"). Not recursive: under
--                        LuaJIT a recursive function read 0.79 to 1.03
--                        against an identical copy of itself (trace
--                        selection), which would hide what is measured
--   emit/return-fixed    `return a, x.v` through a function body's
--                        epilogue: two locals, the epilogue, the return;
--                        against the destructor called by hand before the
--                        return
--   emit/return-call     `return g(a)` through the epilogue: the values
--                        packed with `select("#", …)` and unpacked with
--                        `unpack(t, 1, n)`; against the same by hand with
--                        two locals (the emitter cannot know the count)
--
-- A source that does not build (a base whose emitter predates task 006)
-- gives a benchmark that raises, which the harness reports while the
-- other benchmarks of the file still run (bench/README.md); the built
-- function itself is what is timed, with nothing around it.
local bench = require("bench.lib.bench")
local cli = require("lifetime.cli")

local closed = 0
local MT = {
    __destroy = function(self, reason)
        closed = closed + 1
    end
}

-- The function a chunk built from `.lt` source by cli.build returns when
-- called with `...`; when the build fails (a base without task 006), a
-- function that raises the reason.
local function built(name, source, ...)
    local ok, result = pcall(function(...)
        local output = assert(cli.build(source, name))
        return assert(loadstring(output, "=" .. name))(...)
    end, ...)
    if ok then
        return result
    end
    return function()
        error(name .. ": " .. tostring(result), 0)
    end
end

-- The function a plain Lua chunk loaded directly returns when called
-- with `...`.
local function direct(name, source, ...)
    return assert(loadstring(source, "=" .. name))(...)
end

local function add(name, fn, baseline)
    bench.add(name, fn, {baseline = baseline})
end

-- emit/scoped-loop
add("emit/scoped-loop", built("scoped-loop.lt", [[
local MT = ...
return function()
    for _ = 1, 10 do
        local x = setmetatable({}, MT) @ lifetime.scope
        x.v = 1
    end
end
]], MT), direct("scoped-loop.lua", [[
local MT = ...
local destroy = MT.__destroy
return function()
    for _ = 1, 10 do
        local x = setmetatable({}, MT)
        x.v = 1
        destroy(x, "anchor")
    end
end
]], MT))

-- emit/unscoped-loop: the loop of emit/scoped-loop without the anchor;
-- the chunk has a scoped function too, so it gets the header and the
-- analysis.
local UNSCOPED = [[
local MT = ...
local function elsewhere()
    local y = {} @ lifetime.scope
    return y
end
return function()
    for _ = 1, 10 do
        local x = setmetatable({}, MT)
        x.v = 1
    end
end
]]
add("emit/unscoped-loop", built("unscoped-loop.lt", UNSCOPED, MT), direct("unscoped-loop.lua", (UNSCOPED:gsub(" @ lifetime%.scope", "")), MT))

-- emit/calls
local CALLS = [[
local function elsewhere()
    local y = {} @ lifetime.scope
    return y
end
local function add(a, b)
    return a + b
end
local function sum(n)
    local s = 0
    for i = 1, n do
        s = add(s, i)
    end
    return s
end
return function()
    local t = 0
    for i = 1, 10 do
        t = t + sum(i)
    end
    return t
end
]]
add("emit/calls", built("calls.lt", CALLS), direct("calls.lua", (CALLS:gsub(" @ lifetime%.scope", ""))))

-- emit/return-fixed
add("emit/return-fixed", built("return-fixed.lt", [[
local MT = ...
local function f(a)
    local x = setmetatable({v = a}, MT) @ lifetime.scope
    return a, x.v
end
return function()
    for i = 1, 10 do
        f(i)
    end
end
]], MT), direct("return-fixed.lua", [[
local MT = ...
local destroy = MT.__destroy
local function f(a)
    local x = setmetatable({v = a}, MT)
    local r1, r2 = a, x.v
    destroy(x, "anchor")
    return r1, r2
end
return function()
    for i = 1, 10 do
        f(i)
    end
end
]], MT))

-- emit/return-call
add("emit/return-call", built("return-call.lt", [[
local MT = ...
local function g(a)
    return a, a + 1
end
local function f(a)
    local x = setmetatable({v = a}, MT) @ lifetime.scope
    return g(x.v)
end
return function()
    for i = 1, 10 do
        f(i)
    end
end
]], MT), direct("return-call.lua", [[
local MT = ...
local destroy = MT.__destroy
local function g(a)
    return a, a + 1
end
local function f(a)
    local x = setmetatable({v = a}, MT)
    local r1, r2 = g(x.v)
    destroy(x, "anchor")
    return r1, r2
end
return function()
    for i = 1, 10 do
        f(i)
    end
end
]], MT))
