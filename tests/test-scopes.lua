-- tests/test-scopes.lua: lifetime/init.lua, task 003. Scope records
-- (`lifetime.enter`, `lifetime.exit`), the per-coroutine scope stack, the
-- replacements for `pcall`, `xpcall`, `coroutine.resume` and
-- `coroutine.wrap` that unwind it on the error path, the `lifetime.scope`
-- marker, and hooks (`lifetime.hook`).
--
-- The tests write the block prologue and epilogue of
-- docs/04-transpiler.md, "Blocks: prologue and epilogue on every exit
-- path", by hand, as generated code would:
--
--   local s = enter("<chunk>:<line of end>")
--   ...
--   exit(s, "<chunk>:<line of the exit>")
--
-- Every destruction test logs into a table and compares the whole
-- sequence, with the reason, and checks the log before and after the
-- statement that caused the deaths (CLAUDE.md, rule 3).
local test = require("tests.lib.test")
local lifetime = require("lifetime")

local attach, destroy, discard = lifetime.attach, lifetime.destroy, lifetime.discard
local enter, exit, hook = lifetime.enter, lifetime.exit, lifetime.hook

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

-- The depth of the running coroutine's scope stack, read through a fresh
-- record (its `depth` is one more), which is then exited at once.
local function depth()
    local probe = enter("probe")
    local d = rawget(probe, "depth") - 1
    exit(probe, "probe")
    return d
end

-- The original of a replaced function, kept by the runtime as the upvalue
-- `name` of its replacement (docs/03-runtime.md, "keeping the originals as
-- upvalues"): the stand-in for a `pcall` captured into a local before
-- `lifetime` was required, a catch the runtime cannot see.
local function original(replacement, name)
    local i = 1
    while true do
        local n, v = debug.getupvalue(replacement, i)
        if n == nil then
            error("no upvalue " .. name)
        end
        if n == name then
            return v
        end
        i = i + 1
    end
end

local hidden_pcall = original(pcall, "pcall")
local hidden_resume = original(coroutine.resume, "resume")

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
test.suite("scopes: records")

test.case("enter returns a record with metatable scope, pushed on the stack; exit pops it", function()
    local before = depth()
    local s = enter("t.lt:9")
    test.assert_eq(getmetatable(s), "scope")
    test.assert_eq(tostring(s), "scope")
    test.assert_eq(rawget(s, "depth"), before + 1)
    test.assert_eq(rawget(s, "line"), "t.lt:9")
    local stack = rawget(s, "stack")
    test.assert_true(rawequal(stack[before + 1], s), "the record is on top of the stack")
    test.assert_eq(stack.n, before + 1)
    exit(s, "t.lt:9")
    test.assert_eq(stack.n, before)
    test.assert_eq(stack[before + 1], nil)
    test.assert_eq(depth(), before)
end)

test.case("exit destroys the record's dependents in reverse attachment order, reason anchor, at the exit", function()
    local log = {}
    local s = enter("t.lt:20")
    local a = attach(new_logged(log, "a"), false, s)
    local b = attach(new_logged(log, "b"), false, s)
    local c = attach(new_logged(log, "c"), false, s)
    test.assert_deep_eq(lifetime.dependents(s), {a, b, c})
    test.assert_eq(lifetime.format(a), "(scope, reachable)")
    test.assert_deep_eq(log, {}, "nothing dies before the exit")
    exit(s, "t.lt:18")
    test.assert_deep_eq(log, {"c (anchor)", "b (anchor)", "a (anchor)"})
    for _, x in ipairs({a, b, c}) do
        test.assert_eq(getmetatable(x), "dead")
    end
    -- `<where>` is the position given to exit, the statement of death.
    test.assert_error(function()
        return a.x
    end, "attempt to index a dead table (a, died at t.lt:18, anchor)")
end)

test.case("the example of Cascading death: c, d, a, hook, b", function()
    local log = {}
    local s = enter("t.lt:7")
    local a = attach(new_logged(log, "a"), false, s)
    local b = attach(new_logged(log, "b"), false, a)
    local c = attach(new_logged(log, "c"), false, s)
    local d = attach(new_logged(log, "d"), false, a, c)
    hook(logger(log, "hook on a"), nil, a)
    exit(s, "t.lt:7")
    test.assert_deep_eq(log, {"c (anchor)", "d (anchor)", "a (anchor)", "hook on a (anchor)", "b (anchor)"})
    test.assert_eq(getmetatable(b), "dead")
    test.assert_eq(getmetatable(d), "dead")
end)

test.case("case 3: nested records are independent; each exit kills only its own dependents", function()
    local log = {}
    local outer = enter("t.lt:40")
    local inner = enter("t.lt:39")
    local x = attach(new_logged(log, "x"), false, outer)
    local y = attach(new_logged(log, "y"), false, inner)
    -- Nothing links the records: neither refers to the other.
    for _, v in pairs(inner) do
        test.assert_false(rawequal(v, outer))
    end
    for _, v in pairs(outer) do
        test.assert_false(rawequal(v, inner))
    end
    exit(inner, "t.lt:39")
    test.assert_deep_eq(log, {"y (anchor)"})
    test.assert_true(getmetatable(x) ~= "dead", "x is alive")
    exit(outer, "t.lt:40")
    test.assert_deep_eq(log, {"y (anchor)", "x (anchor)"})
    test.assert_eq(getmetatable(y), "dead")
end)

test.case("each entry is a new record: a loop body's dependent dies at the end of its iteration", function()
    local log = {}
    local records = {}
    for i = 1, 3 do
        local s = enter("t.lt:60")
        records[i] = s
        local x = attach(new_logged(log, "x" .. i), false, s)
        log[#log + 1] = "body " .. i
        exit(s, "t.lt:60")
        test.assert_eq(getmetatable(x), "dead")
    end
    test.assert_deep_eq(log, {"body 1", "x1 (anchor)", "body 2", "x2 (anchor)", "body 3", "x3 (anchor)"})
    test.assert_false(rawequal(records[1], records[2]))
end)

test.case("a record whose dependents were moved away or destroyed has nothing left to kill", function()
    local log = {}
    local s = enter("t.lt:70")
    local keep = {}
    local moved = attach(new_logged(log, "moved"), false, s)
    local gone = attach(new_logged(log, "gone"), false, s)
    attach(moved, false, keep)
    destroy(gone)
    test.assert_deep_eq(log, {"gone (destroy)"})
    exit(s, "t.lt:70")
    test.assert_deep_eq(log, {"gone (destroy)"})
    test.assert_true(getmetatable(moved) ~= "dead", "moved is alive")
    test.assert_deep_eq(lifetime.dependents(keep), {moved})
end)

test.case("the first destructor error is raised at the exit, after the whole cascade; later ones go to destroyerror", function()
    local log = {}
    local before = depth()
    local s = enter("t.lt:80")
    attach(new_logged(log, "a", function()
        error("a failed", 0)
    end), false, s)
    attach(new_logged(log, "b", function()
        error("b failed", 0)
    end), false, s)
    local routed = {}
    local err
    with_handler(function(obj, e)
        routed[#routed + 1] = tostring(obj) .. ": " .. e
    end, function()
        local ok
        ok, err = pcall(exit, s, "t.lt:80")
        test.assert_false(ok)
    end)
    test.assert_eq(err, "b failed")
    test.assert_deep_eq(log, {"b (anchor)", "a (anchor)"})
    test.assert_deep_eq(routed, {"a: a failed"})
    test.assert_eq(depth(), before, "the record was popped all the same")
end)

test.case("a dependent of a record cannot be moved during the scope exit; a fresh object can", function()
    local log = {}
    local other = {}
    local s = enter("t.lt:90")
    local fresh_ok, move_err
    local older = attach({}, false, s)
    attach(new_logged(log, "x", function()
        fresh_ok = pcall(attach, {}, false, other)
        local ok
        ok, move_err = pcall(attach, older, false, other)
        test.assert_false(ok)
    end), false, s)
    exit(s, "t.lt:90")
    test.assert_true(fresh_ok)
    test.assert_true(move_err:find("attempt to move", 1, true) ~= nil, move_err)
end)

test.case("enter in a loop allocates the records and nothing else; an empty record costs no cascade", function()
    local function run(n)
        for _ = 1, n do
            local s = enter("t.lt:100")
            exit(s, "t.lt:100")
        end
    end
    -- One record, measured alone, against the same shape built by hand.
    -- Warm up first: on LuaJIT the count includes the memory of the traces
    -- compiled for the loop, which must exist before the measurement.
    run(5000)
    run(1)
    collectgarbage("collect")
    collectgarbage("stop")
    local c0 = collectgarbage("count")
    run(1)
    local one = collectgarbage("count") - c0
    c0 = collectgarbage("count")
    run(1000)
    local many = collectgarbage("count") - c0
    collectgarbage("restart")
    test.assert_true(one > 0, "a record is a table")
    test.assert_eq(many, 1000 * one, "n records and nothing else")
    -- One record is one table: as large as a table with the same seven
    -- keys built by hand (the record's metatable is shared).
    local key, mt = {}, {}
    local function by_hand()
        local t = {deps = false, strong = false, phase = false, line = "t.lt:100", depth = 1, stack = key}
        t[key] = t
        return setmetatable(t, mt)
    end
    by_hand()
    collectgarbage("collect")
    collectgarbage("stop")
    c0 = collectgarbage("count")
    by_hand()
    local hand = collectgarbage("count") - c0
    collectgarbage("restart")
    test.assert_eq(one, hand, "one record is one table")
end)

------------------------------------------------------------------------
test.suite("scopes: hooks")

test.case("case 1: hooks on a scope interleave with its dependents, last attached first", function()
    local log = {}
    local s = enter("t.lt:3")
    local f = attach(new_logged(log, "f"), false, s)
    hook(logger(log, "after f is still open"), nil, s)
    local g = attach(new_logged(log, "g"), false, s)
    hook(logger(log, "runs first"), nil, s)
    test.assert_deep_eq(log, {})
    exit(s, "t.lt:6")
    test.assert_deep_eq(log, {"runs first (anchor)", "g (anchor)", "after f is still open (anchor)", "f (anchor)"})
    test.assert_eq(getmetatable(f), "dead")
    test.assert_eq(getmetatable(g), "dead")
end)

test.case("case 2: a hook on an object runs after its __destroy, while the object is still usable", function()
    local log = {}
    local conn = new_logged(log, "conn")
    conn.id = "conn"
    lifetime.of(conn)
    hook(function(reason)
        log[#log + 1] = "hook sees " .. conn.id .. " (" .. reason .. ")"
    end, nil, conn)
    destroy(conn)
    test.assert_deep_eq(log, {"conn (destroy)", "hook sees conn (anchor)"})
    test.assert_eq(getmetatable(conn), "dead")
end)

test.case("a hook takes its place among an object's dependents by attachment order", function()
    local log = {}
    local root = new_logged(log, "root")
    local x = attach(new_logged(log, "x"), false, root)
    hook(logger(log, "h1"), nil, root)
    local y = attach(new_logged(log, "y"), false, root)
    hook(logger(log, "h2"), nil, root)
    local z = attach(new_logged(log, "z"), false, root)
    test.assert_eq(#lifetime.dependents(root), 5)
    test.assert_true(rawequal(lifetime.dependents(root)[1], x))
    test.assert_eq(getmetatable(lifetime.dependents(root)[2]), "hook")
    test.assert_true(rawequal(lifetime.dependents(root)[3], y))
    test.assert_true(rawequal(lifetime.dependents(root)[5], z))
    destroy(root)
    test.assert_deep_eq(log, {"root (destroy)", "z (anchor)", "h2 (anchor)", "y (anchor)", "h1 (anchor)", "x (anchor)"})
end)

test.case("a hook is pinned: its anchor holds it, nothing else needs to", function()
    local log = {}
    local probe = setmetatable({}, {__mode = "k"})
    local a = {}
    do
        local h = hook(logger(log, "h"), nil, a)
        probe[h] = true
    end
    collectgarbage("collect")
    collectgarbage("collect")
    test.assert_true(next(probe) ~= nil, "the hook was not collected")
    test.assert_eq(#lifetime.dependents(a), 1)
    destroy(a)
    test.assert_deep_eq(log, {"h (anchor)"})
end)

test.case("an anchor holds nothing strongly but its hooks and pinned dependents", function()
    local probe = setmetatable({}, {__mode = "k"})
    local a = {}
    local pinned = attach({}, true, a)
    do
        local loose = attach({}, false, a)
        probe[loose] = true
    end
    collectgarbage("collect")
    collectgarbage("collect")
    test.assert_eq(next(probe), nil, "the dependent with the term was collected")
    test.assert_deep_eq(lifetime.dependents(a), {pinned})
    -- A dead anchor lets go of its hooks.
    local function make()
        local b = {}
        probe[hook(function()
        end, nil, b)] = true
        return b
    end
    local b = make()
    destroy(b)
    collectgarbage("collect")
    collectgarbage("collect")
    test.assert_eq(next(probe), nil, "the dead hook was collected")
end)

test.case("lifetime.hook(5) and a hook as the function raise attempt to defer", function()
    test.assert_error(function()
        hook(5, nil, {})
    end, "attempt to defer a number value")
    test.assert_error(function()
        hook(nil, nil, {})
    end, "attempt to defer a nil value")
    test.assert_error(function()
        hook({}, nil, {})
    end, "attempt to defer a table value")
    local h = hook(function()
    end, nil, {})
    test.assert_error(function()
        hook(h, nil, {})
    end, "attempt to defer a hook value")
end)

test.case("hook errors name the caller's position; anchors are validated as by @", function()
    local this = debug.getinfo(1, "S").short_src
    local line = debug.getinfo(1, "l").currentline + 2
    local ok, err = pcall(function()
        hook(5, nil, {})
    end)
    test.assert_false(ok)
    test.assert_eq(err, this .. ":" .. line .. ": attempt to defer a number value")
    test.assert_error(function()
        hook(function()
        end, nil, nil)
    end, "attempt to anchor to a nil value")
    test.assert_error(function()
        hook(function()
        end, nil)
    end, "bad argument #3 to 'lifetime.hook' (anchor expected, got no value)")
    local dead = {}
    destroy(dead)
    test.assert_error(function()
        hook(function()
        end, nil, {}, dead)
    end, "attempt to anchor to a dead table")
end)

test.case("calling, indexing or assigning to a hook raises the hook errors; getmetatable is hook", function()
    local h = hook(function()
    end, nil, {})
    test.assert_eq(getmetatable(h), "hook")
    test.assert_error(function()
        h()
    end, "attempt to call a hook value")
    test.assert_error(function()
        return h.fn
    end, "attempt to index a hook value")
    test.assert_error(function()
        h.x = 1
    end, "attempt to index a hook value")
    test.assert_error(function()
        setmetatable(h, {})
    end, "cannot change a protected metatable")
end)

test.case("a named hook renders as hook NAME; an anonymous one as hook: 0x...", function()
    local a = {}
    local cleanup = hook(function()
    end, "cleanup", a)
    test.assert_eq(tostring(cleanup), "hook cleanup")
    test.assert_eq(lifetime.format(cleanup), "hook cleanup")
    local anonymous = hook(function()
    end, nil, a)
    test.assert_true(tostring(anonymous):match("^hook: 0x%x+$") ~= nil, tostring(anonymous))
    test.assert_eq(lifetime.format(anonymous), "hook")
    -- The formula of a hook has no term: it is pinned.
    test.assert_eq(lifetime.format(lifetime.of(cleanup)), tostring(a))
    -- The name is fixed at creation and survives death in the tombstone.
    local moved_to = {other = cleanup}
    test.assert_eq(tostring(moved_to.other), "hook cleanup")
    local where = debug.getinfo(1, "S").short_src .. ":" .. (debug.getinfo(1, "l").currentline + 1)
    destroy(cleanup)
    test.assert_eq(tostring(cleanup), "dead hook cleanup")
    test.assert_error(function()
        return cleanup.x
    end, "attempt to index a dead table (hook cleanup, died at " .. where .. ", destroy)")
    discard(anonymous)
    test.assert_true(tostring(anonymous):match("^dead hook: 0x%x+$") ~= nil, tostring(anonymous))
end)

test.case("destroy(h) runs f('destroy') once; afterwards the hook is dead and destroy and discard do nothing", function()
    local log = {}
    local a = {}
    local h = hook(logger(log, "f"), "h", a)
    destroy(h)
    test.assert_deep_eq(log, {"f (destroy)"})
    test.assert_eq(getmetatable(h), "dead")
    if lifetime.alive then
        test.assert_false(lifetime.alive(h))
    end
    destroy(h)
    discard(h)
    destroy(a)
    test.assert_deep_eq(log, {"f (destroy)"}, "a hook runs at most once")
    test.assert_deep_eq(lifetime.dependents(a), {})
    -- Moving a dead hook raises the dead-object error.
    test.assert_error(function()
        attach(h, false, {})
    end, "attempt to index a dead table (hook h")
end)

test.case("case 6: discard cancels a hook; a hook moved with @ runs when its new anchor dies, still pinned", function()
    local log = {}
    local s = enter("t.lt:120")
    local cancelled = hook(logger(log, "cancelled"), "cancelled", s)
    local moved = hook(logger(log, "moved"), "moved", s)
    hook(logger(log, "stays"), nil, s)
    discard(cancelled)
    test.assert_deep_eq(log, {}, "discard never runs f")
    test.assert_eq(getmetatable(cancelled), "dead")
    local registry = {}
    attach(moved, false, registry)
    test.assert_eq(lifetime.format(lifetime.of(moved)), tostring(registry), "the move kept it pinned")
    exit(s, "t.lt:120")
    test.assert_deep_eq(log, {"stays (anchor)"})
    -- Pinned: nothing but `registry` holds it.
    local probe = setmetatable({[moved] = true}, {__mode = "k"})
    moved = nil -- luacheck: ignore 311 (dropping the only local reference is the point)
    collectgarbage("collect")
    collectgarbage("collect")
    test.assert_true(next(probe) ~= nil)
    destroy(registry)
    test.assert_deep_eq(log, {"stays (anchor)", "moved (anchor)"})
end)

test.case("a hook on several anchors runs when the first of them dies, once", function()
    local log = {}
    local emitter, listener = {}, {}
    hook(logger(log, "unsubscribe"), nil, emitter, listener)
    test.assert_deep_eq(lifetime.dependents(emitter), lifetime.dependents(listener))
    destroy(listener)
    test.assert_deep_eq(log, {"unsubscribe (anchor)"})
    destroy(emitter)
    test.assert_deep_eq(log, {"unsubscribe (anchor)"})
    test.assert_deep_eq(lifetime.dependents(emitter), {})
end)

test.case("a hook's error follows the destructor rule", function()
    local log = {}
    local a = {}
    hook(function()
        log[#log + 1] = "first"
        error("first failed", 0)
    end, nil, a)
    hook(function()
        log[#log + 1] = "second"
        error("second failed", 0)
    end, nil, a)
    local routed = {}
    local ok, err
    with_handler(function(obj, e)
        routed[#routed + 1] = e
        test.assert_eq(getmetatable(obj), "hook", "the dying hook, still usable as an object")
    end, function()
        ok, err = pcall(destroy, a)
    end)
    test.assert_false(ok)
    test.assert_eq(err, "second failed")
    test.assert_deep_eq(log, {"second", "first"})
    test.assert_deep_eq(routed, {"first failed"})
end)

test.case("a hook may be created during a destroy phase and anchored to a live object", function()
    local log = {}
    local survivor = {}
    local root = new_logged(log, "root", function()
        hook(logger(log, "late"), nil, survivor)
    end)
    lifetime.of(root)
    destroy(root)
    test.assert_deep_eq(log, {"root (destroy)"})
    destroy(survivor)
    test.assert_deep_eq(log, {"root (destroy)", "late (anchor)"})
end)

test.case("hooks are compacted with the other dependents and keep their order", function()
    local a = {}
    local log = {}
    local kept = {}
    local function fill()
        for i = 1, 200 do
            if i % 20 == 0 then
                kept[#kept + 1] = hook(logger(log, "h" .. i), nil, a)
            else
                attach({}, false, a)
            end
        end
    end
    fill()
    collectgarbage("collect")
    collectgarbage("collect")
    -- More links reach the limit (256 after the fill) and compact the holes the
    -- collected dependents left; these new ones are collected too.
    local function more()
        for _ = 1, 60 do
            attach({}, false, a)
        end
    end
    more()
    collectgarbage("collect")
    collectgarbage("collect")
    local st
    for k, v in pairs(a) do
        if lifetime.is_state(k) then
            st = v
        end
    end
    test.assert_true(st.deps.seq - st.deps.lo < 100, "compacted: range " .. (st.deps.seq - st.deps.lo))
    local dependents = lifetime.dependents(a)
    test.assert_eq(#dependents, #kept)
    for i = 1, #kept do
        test.assert_true(rawequal(dependents[i], kept[i]), "hook " .. i .. " in order")
    end
    destroy(a)
    local expected = {}
    for i = 200, 20, -20 do
        expected[#expected + 1] = "h" .. i .. " (anchor)"
    end
    test.assert_deep_eq(log, expected)
end)

------------------------------------------------------------------------
test.suite("scopes: the marker")

test.case("lifetime.scope is a marker: tostring, index, assign and call", function()
    test.assert_eq(tostring(lifetime.scope), "lifetime.scope")
    test.assert_error(function()
        return lifetime.scope.x
    end, "attempt to index lifetime.scope")
    test.assert_error(function()
        lifetime.scope.x = 1
    end, "attempt to index lifetime.scope")
    test.assert_error(function()
        lifetime.scope()
    end, "attempt to index lifetime.scope")
    test.assert_true(getmetatable(lifetime.scope) ~= "scope", "the marker is never a scope record")
end)

test.case("attach refuses the marker, through a variable or in a list, and never anchors to it", function()
    local s = lifetime.scope
    test.assert_error(function()
        attach({}, false, s)
    end, "attempt to anchor to lifetime.scope through a variable")
    test.assert_error(function()
        attach({}, false, {}, s)
    end, "attempt to anchor to lifetime.scope through a variable")
    test.assert_error(function()
        hook(function()
        end, nil, s)
    end, "attempt to anchor to lifetime.scope through a variable")
    test.assert_error(function()
        attach(s, false, {})
    end, "attempt to anchor to lifetime.scope through a variable")
    test.assert_error(function()
        destroy(s)
    end, "bad argument #1 to 'destroy' (object expected, got lifetime.scope)")
    test.assert_error(function()
        discard(s)
    end, "bad argument #1 to 'discard' (object expected, got lifetime.scope)")
    test.assert_error(function()
        lifetime.of(s)
    end, "bad argument #1 to 'lifetime.of' (object expected, got lifetime.scope)")
    test.assert_error(function()
        lifetime.format(s)
    end, "bad argument #1 to 'lifetime.format' (lifetime expected, got lifetime.scope)")
    test.assert_deep_eq(lifetime.dependents(s), {})
    -- Still refused after all that.
    test.assert_error(function()
        attach({}, false, s)
    end, "attempt to anchor to lifetime.scope through a variable")
end)

test.case("a scope record reached through a lifetime value cannot be destroyed or moved", function()
    local s = enter("t.lt:140")
    local x = attach({}, false, s)
    local record = lifetime.of(x)[1]
    test.assert_true(rawequal(record, s))
    test.assert_error(function()
        destroy(record)
    end, "bad argument #1 to 'destroy' (object expected, got scope)")
    test.assert_error(function()
        attach(record, false, {})
    end, "attempt to anchor a scope value")
    -- Anchoring to it through the value works while the block is active.
    local y = attach({}, false, lifetime.of(x))
    test.assert_deep_eq(lifetime.dependents(s), {x, y})
    exit(s, "t.lt:140")
    test.assert_eq(getmetatable(y), "dead")
    test.assert_error(function()
        attach({}, false, record)
    end, "attempt to anchor to a dead table")
end)

------------------------------------------------------------------------
test.suite("scopes: the error path")

test.case("case 5: pcall unwinds the records pushed since it began, innermost first, before it returns", function()
    local log = {}
    local before = depth()
    local ok, err = pcall(function()
        local outer = enter("t.lt:160")
        attach(new_logged(log, "x"), false, outer)
        local inner = enter("t.lt:158")
        attach(new_logged(log, "y"), false, inner)
        log[#log + 1] = "raise"
        error("boom")
    end)
    log[#log + 1] = "pcall returned"
    test.assert_false(ok)
    test.assert_true(err:find(": boom$") ~= nil, err)
    test.assert_deep_eq(log, {"raise", "y (anchor)", "x (anchor)", "pcall returned"})
    test.assert_eq(depth(), before, "the stack is back at its depth")
end)

test.case("an unwound record's dependents die at the line of the block's end given to enter", function()
    local x
    pcall(function()
        local s = enter("t.lt:177")
        x = attach({}, false, s)
        error("boom")
    end)
    test.assert_error(function()
        return x.v
    end, "died at t.lt:177, anchor)")
end)

test.case("records of an enclosing block outside the pcall are not unwound", function()
    local log = {}
    local outside = enter("t.lt:190")
    local keep = attach(new_logged(log, "outside"), false, outside)
    pcall(function()
        local s = enter("t.lt:185")
        attach(new_logged(log, "inside"), false, s)
        error("boom")
    end)
    test.assert_deep_eq(log, {"inside (anchor)"})
    test.assert_true(getmetatable(keep) ~= "dead", "keep is alive")
    exit(outside, "t.lt:190")
    test.assert_deep_eq(log, {"inside (anchor)", "outside (anchor)"})
end)

test.case("case 5: xpcall's handler runs at the raise point, before any record is unwound", function()
    local log = {}
    local before = depth()
    local ok, err = xpcall(function()
        local outer = enter("t.lt:200")
        attach(new_logged(log, "x"), false, outer)
        local inner = enter("t.lt:199")
        attach(new_logged(log, "y"), false, inner)
        error("boom", 0)
    end, function(e)
        log[#log + 1] = "handler"
        return "handled " .. e
    end)
    test.assert_false(ok)
    test.assert_eq(err, "handled boom")
    test.assert_deep_eq(log, {"handler", "y (anchor)", "x (anchor)"})
    test.assert_eq(depth(), before)
end)

test.case("case 5: a destructor error during the unwind goes to destroyerror; the original error comes out", function()
    local log = {}
    local routed = {}
    local ok, err
    with_handler(function(obj, e)
        routed[#routed + 1] = tostring(obj) .. ": " .. e
    end, function()
        ok, err = pcall(function()
            local outer = enter("t.lt:220")
            attach(new_logged(log, "x"), false, outer)
            local inner = enter("t.lt:219")
            attach(new_logged(log, "d", function()
                error("d", 0)
            end), false, inner)
            error("boom", 0)
        end)
    end)
    test.assert_false(ok)
    test.assert_eq(err, "boom")
    test.assert_deep_eq(log, {"d (anchor)", "x (anchor)"})
    test.assert_deep_eq(routed, {"d: d"})
end)

test.case("pcall and xpcall return exactly what the call returned, trailing nils included", function()
    local function count(...)
        return select("#", ...), ...
    end
    test.assert_deep_eq({count(pcall(function()
        return 1, nil, 3, nil
    end))}, {5, true, 1, nil, 3, nil})
    local e = {}
    local n, ok, got = count(pcall(error, e))
    test.assert_eq(n, 2)
    test.assert_false(ok)
    test.assert_true(rawequal(got, e))
    n, ok, got = count(xpcall(function()
        return nil
    end, print))
    test.assert_eq(n, 2)
    test.assert_true(ok)
    test.assert_eq(got, nil)
end)

test.case("the wrappers allocate nothing: a loop of pcalls and xpcalls that raise through no scoped block", function()
    local e = {}
    local function raise()
        error(e)
    end
    local function handler(x)
        return x
    end
    local function run(n)
        for _ = 1, n do
            pcall(raise)
            xpcall(raise, handler)
            pcall(handler, 1)
        end
    end
    -- Warm up, so that LuaJIT has compiled the loop before the measurement.
    run(5000)
    collectgarbage("collect")
    collectgarbage("stop")
    local c0 = collectgarbage("count")
    run(1000)
    local used = collectgarbage("count") - c0
    collectgarbage("restart")
    test.assert_eq(used, 0, "KB allocated")
end)

test.case("case 5a: a record a hidden catch left behind dies at the next exit that finds it above itself", function()
    local log = {}
    local before = depth()
    local outer = enter("t.lt:240")
    attach(new_logged(log, "outer x"), false, outer)
    -- `hidden_pcall` is the original pcall, as captured into a local before
    -- `lifetime` was required: the runtime does not see this catch.
    local ok = hidden_pcall(function()
        local r = enter("t.lt:236")
        attach(new_logged(log, "r y"), false, r)
        local r2 = enter("t.lt:235")
        attach(new_logged(log, "r2 z"), false, r2)
        error("boom")
    end)
    test.assert_false(ok)
    test.assert_deep_eq(log, {}, "nothing unwound at the hidden catch")
    test.assert_eq(depth(), before + 3)
    exit(outer, "t.lt:240")
    test.assert_deep_eq(log, {"r2 z (anchor)", "r y (anchor)", "outer x (anchor)"})
    test.assert_eq(depth(), before)
end)

test.case("an exit that unwinds hidden records raises the first destructor error after all of them", function()
    local log = {}
    local routed = {}
    local before = depth()
    local outer = enter("t.lt:260")
    attach(new_logged(log, "outer", function()
        error("outer failed", 0)
    end), false, outer)
    hidden_pcall(function()
        local r = enter("t.lt:255")
        attach(new_logged(log, "left", function()
            error("left failed", 0)
        end), false, r)
        error("boom")
    end)
    local ok, err
    with_handler(function(_, e)
        routed[#routed + 1] = e
    end, function()
        ok, err = pcall(exit, outer, "t.lt:260")
    end)
    test.assert_false(ok)
    test.assert_eq(err, "left failed")
    test.assert_deep_eq(log, {"left (anchor)", "outer (anchor)"})
    test.assert_deep_eq(routed, {"outer failed"})
    test.assert_eq(depth(), before)
end)

test.case("a destructor body that raises with records of its own has them unwound by the runtime's catch", function()
    local log = {}
    local before = depth()
    local root = new_logged(log, "root", function()
        local s = enter("t.lt:270")
        attach(new_logged(log, "inner"), false, s)
        error("root failed", 0)
    end)
    lifetime.of(root)
    local ok, err = pcall(destroy, root)
    test.assert_false(ok)
    test.assert_eq(err, "root failed")
    test.assert_deep_eq(log, {"root (destroy)", "inner (anchor)"})
    test.assert_eq(depth(), before)
end)

------------------------------------------------------------------------
test.suite("scopes: coroutines")

test.case("case 4: a record in a coroutine survives a yield and dies at its exit after the resume", function()
    local log = {}
    local main_before = depth()
    local main = enter("t.lt:300")
    local main_x = attach(new_logged(log, "main x"), false, main)
    local co = coroutine.create(function()
        local s = enter("t.lt:295")
        attach(new_logged(log, "x"), false, s)
        test.assert_eq(depth(), 1, "the coroutine has a stack of its own")
        coroutine.yield("yielded")
        log[#log + 1] = "resumed"
        exit(s, "t.lt:295")
        return "done"
    end)
    local ok, v = coroutine.resume(co)
    test.assert_true(ok)
    test.assert_eq(v, "yielded")
    test.assert_deep_eq(log, {})
    test.assert_eq(depth(), main_before + 1, "the main stack is untouched by the yield")
    ok, v = coroutine.resume(co)
    test.assert_true(ok)
    test.assert_eq(v, "done")
    test.assert_deep_eq(log, {"resumed", "x (anchor)"})
    test.assert_true(getmetatable(main_x) ~= "dead", "main_x is alive")
    exit(main, "t.lt:300")
    test.assert_deep_eq(log, {"resumed", "x (anchor)", "main x (anchor)"})
end)

test.case("case 5b: a coroutine that raises has its records unwound before resume returns false", function()
    local log = {}
    local before = depth()
    local main = enter("t.lt:330")
    attach(new_logged(log, "main"), false, main)
    local co = coroutine.create(function()
        local s = enter("t.lt:325")
        attach(new_logged(log, "z"), false, s)
        local inner = enter("t.lt:324")
        attach(new_logged(log, "w"), false, inner)
        coroutine.yield()
        error("boom", 0)
    end)
    coroutine.resume(co)
    local ok, err = coroutine.resume(co)
    log[#log + 1] = "resume returned"
    test.assert_false(ok)
    test.assert_eq(err, "boom")
    test.assert_deep_eq(log, {"w (anchor)", "z (anchor)", "resume returned"})
    test.assert_eq(depth(), before + 1, "the main stack is untouched")
    exit(main, "t.lt:330")
    test.assert_deep_eq(log, {"w (anchor)", "z (anchor)", "resume returned", "main (anchor)"})
end)

test.case("case 5b: a coroutine.wrap function unwinds the coroutine's records, then re-raises", function()
    local log = {}
    local before = depth()
    local w = coroutine.wrap(function()
        local s = enter("t.lt:345")
        attach(new_logged(log, "z"), false, s)
        coroutine.yield(1, nil, 3)
        error("boom", 0)
    end)
    test.assert_deep_eq({w()}, {1, nil, 3})
    local ok, err = pcall(w)
    log[#log + 1] = "raised"
    test.assert_false(ok)
    test.assert_eq(err, "boom")
    test.assert_deep_eq(log, {"z (anchor)", "raised"})
    test.assert_eq(depth(), before)
end)

test.case("an error in a coroutine's destructor during its unwind goes to destroyerror", function()
    local routed = {}
    local ok, err
    with_handler(function(_, e)
        routed[#routed + 1] = e
    end, function()
        ok, err = coroutine.resume(coroutine.create(function()
            local s = enter("t.lt:360")
            attach(new_logged({}, "z", function()
                error("z failed", 0)
            end), false, s)
            error("boom", 0)
        end))
    end)
    test.assert_false(ok)
    test.assert_eq(err, "boom")
    test.assert_deep_eq(routed, {"z failed"})
end)

test.case("a refused resume (a running coroutine resuming itself) leaves its stack alone", function()
    local log = {}
    local co
    co = coroutine.create(function()
        local s = enter("t.lt:380")
        attach(new_logged(log, "x"), false, s)
        local ok, err = coroutine.resume(co)
        log[#log + 1] = tostring(ok) .. " " .. tostring(err):gsub("^.*: ", "")
        exit(s, "t.lt:380")
    end)
    assert(coroutine.resume(co))
    test.assert_deep_eq(log, {"false cannot resume running coroutine", "x (anchor)"})
end)

test.case("a hidden resume of a dead coroutine and resume of non-threads behave as the original", function()
    local co = coroutine.create(function()
    end)
    coroutine.resume(co)
    local a1, a2 = coroutine.resume(co)
    local b1, b2 = hidden_resume(co)
    test.assert_eq(a1, b1)
    test.assert_eq(a2, b2)
    test.assert_error(function()
        coroutine.resume(5)
    end, "coroutine expected")
end)

test.case("a suspended coroutine whose hook refers to it can still be collected", function()
    -- The runtime's table of coroutine stacks must not keep a coroutine
    -- alive through the stack's records (CLAUDE.md, rule 6).
    local probe = setmetatable({}, {__mode = "k"})
    local function start()
        local co
        co = coroutine.create(function()
            local s = enter("t.lt:400")
            hook(function()
                return co
            end, nil, s)
            coroutine.yield()
            exit(s, "t.lt:400")
        end)
        coroutine.resume(co)
        probe[co] = true
    end
    start()
    collectgarbage("collect")
    collectgarbage("collect")
    collectgarbage("collect")
    test.assert_eq(next(probe), nil, "the coroutine was collected")
end)

-- Case 7 of the task (a suspended coroutine dropped with a record whose
-- dependent dies by "unreachable" after collectgarbage) needs the record's
-- sentinel, which task 004 provides. Not tested here; see the task file's
-- review log.

------------------------------------------------------------------------
test.suite("scopes: the replaced globals")

test.case("the runtime exports enter, exit, hook and scope, and no drop, caller or exit_main", function()
    test.assert_eq(type(lifetime.enter), "function")
    test.assert_eq(type(lifetime.exit), "function")
    test.assert_eq(type(lifetime.hook), "function")
    test.assert_eq(lifetime.drop, nil)
    test.assert_eq(lifetime.caller, nil)
    test.assert_eq(lifetime.exit_main, nil)
    test.assert_eq(rawget(lifetime, "S"), nil)
end)

-- A fresh program captures the originals before `require("lifetime")` and
-- compares: which globals were replaced, and whether each replacement
-- returns or raises what the original does. Each line it prints is
-- `name<TAB>ok` or `name<TAB>orig | new`.
local COMPARE = [==[
local orig = {
    pcall = pcall, xpcall = xpcall, error = error,
    create = coroutine.create, resume = coroutine.resume, wrap = coroutine.wrap,
    yield = coroutine.yield, status = coroutine.status, running = coroutine.running,
}
local lifetime = require("lifetime")
local function same(name, a, b) print(name .. "\t" .. (a == b and "ok" or (tostring(a) .. " | " .. tostring(b)))) end
same("pcall replaced", rawequal(orig.pcall, pcall), false)
same("xpcall replaced", rawequal(orig.xpcall, xpcall), false)
same("resume replaced", rawequal(orig.resume, coroutine.resume), false)
same("wrap replaced", rawequal(orig.wrap, coroutine.wrap), false)
for _, k in ipairs({"create", "yield", "status", "running"}) do
    same(k .. " untouched", rawequal(orig[k], coroutine[k]), true)
end
same("error untouched", rawequal(orig.error, error), true)

local function pack(...)
    local t = {select("#", ...)}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        t[#t + 1] = type(v) .. ":" .. tostring(v)
    end
    return table.concat(t, ",")
end
local E = {}
local function handler(m) return "h:" .. tostring(m) end
local calls = {
    function(p) return p(function() return 1, nil, 3, nil end) end,
    function(p) return p(function() error("x") end) end,
    function(p) return p(function() error("x", 0) end) end,
    function(p) return p(function() error(E) end) end,
    function(p) return p(function() error(5, 0) end) end,
    function(p) return p(function() error() end) end,
    function(p) return p(error) end,
    function(p) return p(nil) end,
    function(p) return p(function(...) return ... end, 1, nil, 2) end,
}
for i, call in ipairs(calls) do
    same("pcall " .. i, pack(call(orig.pcall)), pack(call(pcall)))
end
local xcalls = {
    function(x) return x(function() return 1, nil end, handler) end,
    function(x) return x(function() error("x") end, handler) end,
    function(x) return x(function() error(E) end, handler) end,
    function(x) return x(function() error("x") end, function() error("in handler") end) end,
    function(x) return x(function(...) return ... end, handler, 1, nil, 2) end,
}
for i, call in ipairs(xcalls) do
    same("xpcall " .. i, pack(call(orig.xpcall)), pack(call(xpcall)))
end

local bodies = {
    function(...) local a = coroutine.yield(1, nil, ...) return a, nil end,
    function() error("boom") end,
    function() error("boom", 0) end,
    function() error(5, 0) end,
    function() error(E) end,
    function() coroutine.yield() error(nil) end,
}
for i, body in ipairs(bodies) do
    local c1, c2 = orig.create(body), orig.create(body)
    for step = 1, 3 do
        same("resume " .. i .. "." .. step, pack(orig.resume(c1, "a", nil)), pack(coroutine.resume(c2, "a", nil)))
    end
    -- The wrap function called from a Lua function on one line, so the
    -- position prefix of a re-raised string is the same for both. Not a
    -- tail call: on Lua 5.1 a tail call keeps the caller's frame below a
    -- C function (the original) and replaces it below a Lua function (the
    -- replacement), so the prefix of `return w()` differs there; see the
    -- task file, "Spec issues found".
    local w1, w2 = orig.wrap(body), coroutine.wrap(body)
    for step = 1, 3 do
        local r1 = pack(orig.pcall(function() return pack(w1("a", nil)) end)) local r2 = pack(orig.pcall(function() return pack(w2("a", nil)) end))
        same("wrap " .. i .. "." .. step, r1, r2)
    end
end
-- A wrap function called directly from pcall (a C caller: no prefix).
local w1, w2 = orig.wrap(function() error("c", 0) end), coroutine.wrap(function() error("c", 0) end)
same("wrap from C", pack(orig.pcall(w1)), pack(orig.pcall(w2)))
]==]

test.case("requiring the runtime replaces exactly pcall, xpcall, coroutine.resume and coroutine.wrap; each returns or raises what the original does", function()
    local out, err = run_program(COMPARE)
    test.assert_eq(err, "")
    local lines, bad = 0, {}
    for line in out:gmatch("[^\n]+") do
        lines = lines + 1
        if not line:find("\tok$") then
            bad[#bad + 1] = line
        end
    end
    test.assert_true(lines >= 60, "the comparison ran: " .. lines .. " lines\n" .. out)
    test.assert_deep_eq(bad, {})
end)

return test
