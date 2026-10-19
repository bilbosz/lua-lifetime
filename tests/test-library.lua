-- tests/test-library.lua: lifetime/init.lua, task 021. The library form
-- of docs/02-semantics.md, "The library form": `lifetime.attach(obj, a1,
-- …)`, `lifetime.hook(f, a1, …)`, `lifetime.named_hook(name, f, a1, …)`
-- and `lifetime.block(fn, …)`, written by a program that is not
-- transpiled. The emitter's own output is covered by tests/test-emit.lua;
-- here the calls are written by hand, as such a program writes them.
--
-- Every destruction test logs into a table and compares the whole
-- sequence, with the reason, and checks the log before and after the
-- statement that caused the deaths (CLAUDE.md, rule 3).
local test = require("tests.lib.test")
local lifetime = require("lifetime")

local attach, hook, named_hook, block = lifetime.attach, lifetime.hook, lifetime.named_hook, lifetime.block
local destroy, alive = lifetime.destroy, lifetime.alive

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

local this = debug.getinfo(1, "S").short_src

test.suite("library: attach and hook")

test.case("attach takes the anchors after the object and returns it", function()
    local a, b = {}, {}
    local log = {}
    local x = new_logged(log, "x")
    test.assert_true(rawequal(attach(x, a), x), "the expression form keeps its value")
    test.assert_eq(lifetime.format(lifetime.of(x)), "(" .. tostring(a) .. ", reachable)")
    attach(x, a, b)
    test.assert_eq(lifetime.format(lifetime.of(x)), "(" .. tostring(a) .. ", " .. tostring(b) .. ", reachable)", "the list form")
    attach(x, lifetime.pin(b))
    test.assert_eq(lifetime.format(lifetime.of(x)), tostring(b), "pinned: no term")
    test.assert_deep_eq(lifetime.dependents(b), {x})
    test.assert_deep_eq(lifetime.dependents(a), {})
    test.assert_deep_eq(log, {})
    destroy(b)
    test.assert_deep_eq(log, {"x (anchor)"})
    test.assert_false(alive(x))
end)

test.case("attach errors name the caller's position and the argument's number", function()
    local a = {}
    local err = test.assert_error(function()
        attach({})
    end, "bad argument #2 to 'lifetime.attach' (anchor expected, got no value)")
    test.assert_true(err:find(this, 1, true) ~= nil, err)
    test.assert_error(function()
        attach({}, nil)
    end, "attempt to anchor to a nil value")
    test.assert_error(function()
        attach(5, a)
    end, "attempt to anchor a number value")
    destroy(a)
    test.assert_error(function()
        attach({}, a)
    end, "attempt to anchor to a dead table")
end)

test.case("hook takes the anchors after the function; the hook runs after its anchor's body", function()
    local log = {}
    local a = new_logged(log, "a")
    local h = hook(logger(log, "h"), a)
    test.assert_eq(getmetatable(h), "hook")
    test.assert_true(tostring(h):find("^hook: 0x") ~= nil, tostring(h))
    test.assert_eq(lifetime.format(h), "hook")
    local b = {}
    local both = hook(logger(log, "both"), a, b)
    test.assert_deep_eq(lifetime.dependents(a), {h, both})
    test.assert_deep_eq(log, {})
    destroy(a)
    test.assert_deep_eq(log, {"a (destroy)", "both (anchor)", "h (anchor)"})
    test.assert_false(alive(h))
    test.assert_false(alive(both))
    test.assert_deep_eq(lifetime.dependents(b), {}, "a dead hook left b's list")
end)

test.case("named_hook takes the name first; the name shows in tostring and format", function()
    local log = {}
    local a = {}
    local cleanup = named_hook("cleanup", logger(log, "cleanup"), a)
    test.assert_eq(tostring(cleanup), "hook cleanup")
    test.assert_eq(lifetime.format(cleanup), "hook cleanup")
    destroy(cleanup)
    test.assert_deep_eq(log, {"cleanup (destroy)"})
    local err = test.assert_error(function()
        cleanup.x = 1
    end, "attempt to assign to a dead table (hook cleanup, died at ")
    test.assert_true(err:find(this, 1, true) ~= nil, err)
end)

test.case("hook errors: the function, the name, the anchors", function()
    local a = {}
    local err = test.assert_error(function()
        hook(5, a)
    end, "attempt to defer a number value")
    test.assert_true(err:find(this, 1, true) ~= nil, err)
    test.assert_error(function()
        named_hook("h", 5, a)
    end, "attempt to defer a number value")
    test.assert_error(function()
        hook(function()
        end)
    end, "bad argument #2 to 'lifetime.hook' (anchor expected, got no value)")
    test.assert_error(function()
        named_hook("h", function()
        end)
    end, "bad argument #3 to 'lifetime.named_hook' (anchor expected, got no value)")
    err = test.assert_error(function()
        named_hook(nil, function()
        end, a)
    end, "bad argument #1 to 'lifetime.named_hook' (string expected, got nil)")
    test.assert_true(err:find(this, 1, true) ~= nil, err)
    test.assert_error(function()
        hook(function()
        end, nil)
    end, "attempt to anchor to a nil value")
end)

test.suite("library: block")

test.case("block runs the function with the record first and returns every result", function()
    local seen
    local r1, r2, r3 = block(function(scope, p, q)
        seen = scope
        test.assert_eq(getmetatable(scope), "scope")
        test.assert_eq(tostring(scope), "scope")
        return p + q, nil, "z"
    end, 1, 2)
    test.assert_eq(r1, 3)
    test.assert_eq(r2, nil)
    test.assert_eq(r3, "z")
    test.assert_eq(select("#", block(function()
        return nil, nil
    end)), 2, "trailing nils survive")
    test.assert_eq(select("#", block(function()
    end)), 0)
    test.assert_true(seen ~= nil)
end)

test.case("dependents of the record die when the function returns, newest first, with reason anchor", function()
    local log = {}
    local x, y
    local result = block(function(scope)
        x = attach(new_logged(log, "x"), scope)
        y = attach(new_logged(log, "y"), scope)
        hook(logger(log, "h"), scope)
        test.assert_deep_eq(log, {}, "nothing dies before the exit")
        log[#log + 1] = "body done"
        return "r"
    end)
    test.assert_eq(result, "r")
    test.assert_deep_eq(log, {"body done", "h (anchor)", "y (anchor)", "x (anchor)"})
    test.assert_false(alive(x))
    test.assert_false(alive(y))
    test.assert_eq(getmetatable(x), "dead")
end)

test.case("the tombstone names the function's position as where the block exited", function()
    local log = {}
    local x
    local fn = function(scope)
        x = attach(new_logged(log, "x"), scope)
    end
    local where = this .. ":" .. debug.getinfo(fn, "S").linedefined
    block(fn)
    test.assert_deep_eq(log, {"x (anchor)"})
    test.assert_error(function()
        return x.v
    end, "attempt to index a dead table (x, died at " .. where .. ", anchor)")
end)

test.case("nested blocks exit innermost first; the outer's dependents survive the inner's exit", function()
    local log = {}
    block(function(outer)
        local a = attach(new_logged(log, "a"), outer)
        block(function(inner)
            attach(new_logged(log, "b"), inner)
            hook(logger(log, "hb"), inner)
            log[#log + 1] = "inner body"
        end)
        test.assert_true(alive(a))
        log[#log + 1] = "after inner"
    end)
    test.assert_deep_eq(log, {"inner body", "hb (anchor)", "b (anchor)", "after inner", "a (anchor)"})
end)

test.case("a dependent of the record that nothing refers to is the collector's, before the exit", function()
    -- docs/02-semantics.md, "The implicit `reachable` term": `x @ scope`
    -- dies with the block at the latest, or earlier when nothing refers
    -- to it. Pinned with collectgarbage("collect") (CLAUDE.md, rule 3).
    local log = {}
    block(function(scope)
        attach(new_logged(log, "loose"), scope)
        local kept = attach(new_logged(log, "kept"), scope)
        attach(new_logged(log, "pinned"), lifetime.pin(scope))
        collectgarbage("collect")
        collectgarbage("collect")
        test.assert_deep_eq(log, {"loose (unreachable)"})
        test.assert_true(alive(kept))
    end)
    test.assert_deep_eq(log, {"loose (unreachable)", "pinned (anchor)", "kept (anchor)"})
end)

test.case("an error in the function unwinds the record at the raise point, before pcall returns", function()
    local log = {}
    local ok, err = pcall(function()
        block(function(scope)
            attach(new_logged(log, "x", function()
                log[#log + 1] = "body sees the error propagating"
            end), scope)
            hook(logger(log, "h"), scope)
            error("boom")
        end)
    end)
    test.assert_false(ok)
    test.assert_true(err:find("boom", 1, true) ~= nil, err)
    test.assert_deep_eq(log, {"h (anchor)", "x (anchor)", "body sees the error propagating"})
    -- The stack is clean: a later block is unaffected.
    block(function(scope)
        attach(new_logged(log, "y"), scope)
    end)
    test.assert_deep_eq(log, {"h (anchor)", "x (anchor)", "body sees the error propagating", "y (anchor)"})
end)

test.case("a destructor error at the exit is raised at the block call, after the whole cascade", function()
    local log = {}
    local ok, err = pcall(block, function(scope)
        attach(new_logged(log, "first", function()
            error("first failed", 0)
        end), scope)
        attach(new_logged(log, "second"), scope)
    end)
    test.assert_false(ok)
    test.assert_eq(err, "first failed")
    test.assert_deep_eq(log, {"second (anchor)", "first (anchor)"})
end)

test.case("the function may yield; the record lives across the yield", function()
    local log = {}
    local co = coroutine.wrap(function()
        block(function(scope)
            attach(new_logged(log, "x"), scope)
            coroutine.yield("yielded")
            log[#log + 1] = "resumed"
        end)
        return "done"
    end)
    test.assert_eq(co(), "yielded")
    test.assert_deep_eq(log, {})
    test.assert_eq(co(), "done")
    test.assert_deep_eq(log, {"resumed", "x (anchor)"})
end)

test.case("the record is dead after the block: anchoring to it raises attempt to anchor to a dead scope", function()
    local saved
    block(function(scope)
        saved = scope
    end)
    test.assert_error(function()
        attach({}, saved)
    end, "attempt to anchor to a dead scope")
    test.assert_error(function()
        hook(function()
        end, saved)
    end, "attempt to anchor to a dead scope")
    test.assert_error(function()
        attach({}, saved, {})
    end, "attempt to anchor to a dead scope")
end)

test.case("block accepts only a function, and the error names the caller", function()
    local err = test.assert_error(function()
        block(5)
    end, "bad argument #1 to 'lifetime.block' (function expected, got number)")
    test.assert_true(err:find(this, 1, true) ~= nil, err)
    test.assert_error(function()
        block()
    end, "bad argument #1 to 'lifetime.block' (function expected, got nil)")
end)

test.case("a block inside a destructor body is a cascade of its own", function()
    local log = {}
    local a = new_logged(log, "a", function()
        block(function(scope)
            attach(new_logged(log, "inner"), scope)
            log[#log + 1] = "a's body"
        end)
    end)
    attach(new_logged(log, "dep"), a)
    destroy(a)
    test.assert_deep_eq(log, {"a (destroy)", "a's body", "inner (anchor)", "dep (anchor)"})
end)
