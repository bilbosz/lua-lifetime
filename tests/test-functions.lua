-- tests/test-functions.lua: lifetime/init.lua, task 012. Functions,
-- coroutines and userdata as dependents: their state records in the
-- weak-keyed side table (docs/03-runtime.md, "The state of an object"),
-- their deaths by cascade, by `destroy` and by the collector, the death
-- remembered so that `lifetime.alive` and `@` see it
-- (docs/02-semantics.md, "Tombstones and `lifetime.alive`";
-- docs/05-decisions.md, "A dead function, coroutine or userdata is
-- remembered, not caught"), error positions (task 002, review finding
-- F3), and the two runtime follow-ups of task 007's review (the default
-- `destroyerror` flushes standard output; a `coroutine.wrap` error).
--
-- A function or a coroutine has no body of its own unless its type's
-- shared metatable has a `__destroy`, so where a test needs the order of
-- deaths it logs through a `newproxy(true)` userdata, whose metatable is
-- its own, or reads `lifetime.alive` of the function from the bodies of
-- the tables around it. Every destruction test compares the whole log and
-- checks it before and after the statement that caused the deaths
-- (CLAUDE.md, rule 3). A death by `reachable` is pinned with
-- `collectgarbage("collect")`, twice when a weak table must have cleared;
-- objects the collector must find are made on a coroutine that is then
-- dropped (`run_dropped`), and objects that must survive are held by the
-- test (CLAUDE.md, rule 6).
local test = require("tests.lib.test")
local lifetime = require("lifetime")

local attach, destroy, discard = lifetime.attach, lifetime.destroy, lifetime.discard
local enter, exit, pin, alive = lifetime.enter, lifetime.exit, lifetime.pin, lifetime.alive

local THIS_FILE = debug.getinfo(1, "S").short_src

-- The line of the caller, as `chunk:line` for a `<where>`.
local function here()
    return THIS_FILE .. ":" .. debug.getinfo(2, "l").currentline
end

local function collect()
    collectgarbage("collect")
end

-- Runs `make` on a coroutine of its own and lets the coroutine go: what
-- `make` created and did not hand out is then referenced by nothing, not
-- even by a stale slot of the test's own stack.
local function run_dropped(make)
    local ok, err = coroutine.resume(coroutine.create(make))
    if not ok then
        error(err, 0)
    end
end

-- A logging table: `__tostring` gives `name`, `__destroy` appends `name
-- (reason)` to `log`, and `extra(self, reason)` runs inside the body when
-- given.
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

-- The same as a userdata: a `newproxy(true)` whose own metatable has the
-- `__destroy` (docs/02-semantics.md, "`__destroy` and reasons", rule 1:
-- "the shared per-type metatable read by `debug.getmetatable`", which for
-- a userdata is its own).
local function new_logged_userdata(log, name, extra)
    local u = newproxy(true)
    local mt = getmetatable(u)
    mt.__tostring = function()
        return name
    end
    mt.__destroy = function(self, reason)
        log[#log + 1] = name .. " (" .. reason .. ")"
        if extra then
            extra(self, reason)
        end
    end
    return u
end

-- The runtime's side table (docs/03-runtime.md, "The state of an
-- object"), found among the upvalues of `lifetime.alive`, which reads it.
-- Tests only look at it.
local function side_table()
    local i = 1
    while true do
        local name, value = debug.getupvalue(alive, i)
        if name == nil then
            error("lifetime.alive has no upvalue `side`")
        end
        if name == "side" then
            return value
        end
        i = i + 1
    end
end

local function count_entries(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
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

-- Whether `record` refers to `x` as a key or a value, one level deep.
local function refers_to(record, x)
    for k, v in pairs(record) do
        if rawequal(k, x) or rawequal(v, x) then
            return true
        end
    end
    return false
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

-- Run `fn` with `mt` as the shared metatable of `sample`'s type
-- (`debug.setmetatable`), restoring the previous one whatever happens.
local function with_type_metatable(sample, mt, fn)
    local saved = debug.getmetatable(sample)
    debug.setmetatable(sample, mt)
    local ok, err = pcall(fn)
    debug.setmetatable(sample, saved)
    if not ok then
        error(err, 0)
    end
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
-- suite, from the repository root, with standard output and standard
-- error going to one file, as a terminal or `2>&1` merges them; returns
-- what was written, in the order it reached the file.
local function run_merged(source)
    local interpreter = arg and arg[-1] or "lua5.1"
    local script, out = os.tmpname(), os.tmpname()
    local f = assert(io.open(script, "wb"))
    f:write("package.path = './?.lua;./?/init.lua;' .. package.path\n", source)
    f:close()
    os.execute(string.format("%s %s >%s 2>&1", shell_quote(interpreter), shell_quote(script), shell_quote(out)))
    local output = read_file(out)
    os.remove(script)
    os.remove(out)
    return output, script
end

------------------------------------------------------------------------
test.suite("functions, coroutines, userdata: the side table")

test.case("case 1: a function dies in its place in the cascade; the side record holds the anchors only", function()
    local side = side_table()
    local log = {}
    local a = new_logged(log, "a")
    local f = function()
    end
    -- x1 is attached before f and x2 after it: newest first, x2 dies
    -- before f and x1 after it, which is where f dies.
    local seen = {}
    local x1 = attach(new_logged(log, "x1", function()
        seen.x1 = alive(f)
    end), false, a)
    attach(f, false, a)
    local x2 = attach(new_logged(log, "x2", function()
        seen.x2 = alive(f)
    end), false, a)

    local st = side[f]
    test.assert_eq(type(st), "table", "f has a record in the side table")
    test.assert_false(refers_to(st, f), "the record never refers to its key")
    test.assert_eq(rawget(st, "n"), 1)
    test.assert_true(rawequal(st[1], a), "the anchor")
    test.assert_eq(type(st[2]), "number", "the sequence number")
    test.assert_deep_eq(lifetime.dependents(a), {x1, f, x2})
    test.assert_true(alive(f))

    test.assert_deep_eq(log, {})
    destroy(a)
    test.assert_deep_eq(log, {"a (destroy)", "x2 (anchor)", "x1 (anchor)"})
    test.assert_deep_eq(seen, {x2 = true, x1 = false}, "f died after x2 and before x1")
    test.assert_false(alive(f))
    test.assert_deep_eq(lifetime.dependents(a), {})
    test.assert_eq(type(f), "function", "a dead function stays a function")
    test.assert_eq(rawget(st, "n"), 0)
    test.assert_eq(st[1], nil, "the dead record holds no anchor")
    test.assert_false(refers_to(st, a))
end)

test.case("case 2: a coroutine dies with its anchor; coroutine functions still work on it", function()
    local log = {}
    local a = new_logged(log, "a")
    local co = coroutine.create(function(x)
        local y = coroutine.yield(x + 1)
        return y * 2
    end)
    attach(co, false, a)
    test.assert_deep_eq(lifetime.dependents(a), {co})
    test.assert_true(alive(co))
    destroy(a)
    test.assert_deep_eq(log, {"a (destroy)"})
    test.assert_false(alive(co))
    test.assert_deep_eq(lifetime.dependents(a), {})
    -- Calls and other uses are not caught (docs/02-semantics.md,
    -- "Tombstones and `lifetime.alive`").
    test.assert_eq(coroutine.status(co), "suspended")
    test.assert_deep_eq({coroutine.resume(co, 1)}, {true, 2})
    test.assert_deep_eq({coroutine.resume(co, 5)}, {true, 10})
    test.assert_eq(coroutine.status(co), "dead")
    test.assert_false(alive(co))
end)

test.case("case 3: userdata die in their place in the cascade with their own __destroy and reason", function()
    local log = {}
    local a = new_logged(log, "a")
    local x1 = attach(new_logged(log, "x1"), false, a)
    local u = attach(new_logged_userdata(log, "u"), false, a)
    local plain = attach(newproxy(false), false, a)
    local x2 = attach(new_logged(log, "x2"), false, a)
    test.assert_deep_eq(lifetime.dependents(a), {x1, u, plain, x2})
    test.assert_deep_eq(log, {})
    destroy(a)
    test.assert_deep_eq(log, {"a (destroy)", "x2 (anchor)", "u (anchor)", "x1 (anchor)"})
    test.assert_false(alive(u))
    test.assert_false(alive(plain))
    -- Not caught: the metatable and its methods are untouched.
    test.assert_eq(tostring(u), "u")
    test.assert_eq(type(getmetatable(u).__destroy), "function")
end)

test.case("case 4: destroy(f) directly; a second destroy is a no-op; @ on it raises at the caller", function()
    local log = {}
    local u = new_logged_userdata(log, "u")
    local b = {}
    local f = function()
    end
    local where = here(); destroy(f)
    test.assert_false(alive(f))
    destroy(f)
    discard(f)
    local err = test.assert_error(function()
        attach(f, false, b)
    end, "attempt to move a dead function (" .. tostring(f) .. ", died at " .. where .. ", destroy)")
    test.assert_eq(err:sub(1, #THIS_FILE), THIS_FILE, "positioned at the caller")
    test.assert_deep_eq(lifetime.dependents(b), {})

    -- With a body: it runs once, with reason "destroy".
    attach(u, false, b)
    test.assert_deep_eq(log, {})
    destroy(u)
    test.assert_deep_eq(log, {"u (destroy)"})
    destroy(u)
    test.assert_deep_eq(log, {"u (destroy)"}, "no-op")
    test.assert_deep_eq(lifetime.dependents(b), {}, "unlinked from its anchor")
    test.assert_error(function()
        attach(u, false, b)
    end, "attempt to move a dead userdata (u, died at ")

    -- A coroutine the runtime never saw.
    local co = coroutine.create(function()
    end)
    destroy(co)
    test.assert_false(alive(co))
    test.assert_error(function()
        attach(co, false, b)
    end, "attempt to move a dead thread (")

    -- `@ lifetime.reachable` and a pinned value refuse it too.
    test.assert_error(function()
        attach(f, false, lifetime.reachable)
    end, "attempt to move a dead function")
    test.assert_error(function()
        attach(f, false, pin(b))
    end, "attempt to move a dead function")
end)

test.case("discard on a function, coroutine or userdata skips its body", function()
    local log = {}
    local a = {}
    local u = attach(new_logged_userdata(log, "u"), false, a)
    discard(u)
    test.assert_deep_eq(log, {})
    test.assert_false(alive(u))
    test.assert_deep_eq(lifetime.dependents(a), {})
    destroy(u)
    test.assert_deep_eq(log, {}, "destroy after discard is a no-op")
end)

test.case("lifetime.of and lifetime.format of a function, coroutine or userdata", function()
    local a = setmetatable({}, {__tostring = function()
        return "a"
    end})
    local b = setmetatable({}, {__tostring = function()
        return "b"
    end})
    local f = function()
    end
    test.assert_true(rawequal(lifetime.of(f), lifetime.reachable), "the default lifetime")
    test.assert_eq(lifetime.format(f), "reachable")
    test.assert_eq(side_table()[f], nil, "lifetime.of needs no record")
    attach(f, false, a)
    test.assert_true(lifetime.of(f) == lifetime.of(attach({}, false, a)), "(a, reachable)")
    test.assert_eq(lifetime.format(f), "(a, reachable)")
    attach(f, false, a, b)
    test.assert_eq(lifetime.format(f), "(a, b, reachable)")
    local co = coroutine.create(function()
    end)
    attach(co, false, pin(a))
    test.assert_eq(lifetime.format(co), "a")
    test.assert_true(lifetime.of(co) == pin(a))
    attach(f, false, lifetime.reachable)
    test.assert_true(rawequal(lifetime.of(f), lifetime.reachable))
    test.assert_eq(lifetime.format(f), "reachable")

    local where = here(); destroy(f)
    local err = test.assert_error(function()
        lifetime.of(f)
    end, "attempt to index a dead function (" .. tostring(f) .. ", died at " .. where .. ", destroy)")
    test.assert_eq(err:sub(1, #THIS_FILE), THIS_FILE)
    err = test.assert_error(function()
        lifetime.format(f)
    end, "attempt to index a dead function (")
    test.assert_eq(err:sub(1, #THIS_FILE), THIS_FILE)
    destroy(a)
    test.assert_false(alive(co))
end)

test.case("a move: the function leaves its old anchors' lists and dies with its new anchor only", function()
    local log = {}
    local a, b = new_logged(log, "a"), new_logged(log, "b")
    local u = attach(new_logged_userdata(log, "u"), false, a)
    attach(u, false, b)
    test.assert_deep_eq(lifetime.dependents(a), {})
    test.assert_deep_eq(lifetime.dependents(b), {u})
    destroy(a)
    test.assert_deep_eq(log, {"a (destroy)"})
    test.assert_true(alive(u))
    destroy(b)
    test.assert_deep_eq(log, {"a (destroy)", "b (destroy)", "u (anchor)"})
    test.assert_false(alive(u))
end)

test.case("the list form: a function dies with whichever anchor dies first and leaves the other", function()
    local log = {}
    local a, b = new_logged(log, "a"), new_logged(log, "b")
    local u = attach(new_logged_userdata(log, "u"), false, a, b)
    test.assert_deep_eq(lifetime.dependents(a), {u})
    test.assert_deep_eq(lifetime.dependents(b), {u})
    destroy(b)
    test.assert_deep_eq(log, {"b (destroy)", "u (anchor)"})
    test.assert_deep_eq(lifetime.dependents(a), {})
    destroy(a)
    test.assert_deep_eq(log, {"b (destroy)", "u (anchor)", "a (destroy)"})
end)

test.case("pinned: an unreferenced coroutine held by its anchor survives collections and dies with it", function()
    local log = {}
    local a = new_logged(log, "a")
    local probe = setmetatable({}, {__mode = "k"})
    run_dropped(function()
        local co = coroutine.create(function()
        end)
        probe[co] = true
        attach(co, false, pin(a))
    end)
    collect()
    collect()
    local co = next(probe)
    test.assert_eq(type(co), "thread", "the anchor holds it")
    test.assert_deep_eq(lifetime.dependents(a), {co})
    test.assert_true(alive(co))
    destroy(a)
    test.assert_deep_eq(log, {"a (destroy)"})
    test.assert_false(alive(co))
    test.assert_deep_eq(lifetime.dependents(a), {})
end)

test.case("scope exit: a function anchored to a scope record dies in reverse attachment order", function()
    local log = {}
    local held = {}
    local s = enter("t.lt:10")
    held[1] = attach(new_logged(log, "x1"), false, s)
    held[2] = attach(new_logged_userdata(log, "u"), false, s)
    local f = attach(function()
    end, false, s)
    held[3] = attach(new_logged(log, "x2", function()
        log[#log + 1] = "f alive: " .. tostring(alive(f))
    end), false, s)
    local list = rawget(s, "deps")
    test.assert_eq(rawget(list, "other"), true, "the record knows it has a dependent in the side table")
    test.assert_deep_eq(log, {})
    exit(s, "t.lt:14")
    test.assert_deep_eq(log, {"x2 (anchor)", "f alive: true", "u (anchor)", "x1 (anchor)"})
    test.assert_false(alive(f))
    test.assert_error(function()
        attach(f, false, {})
    end, "attempt to move a dead function (" .. tostring(f) .. ", died at t.lt:14, anchor)")

    -- The emptied list of that record is reused by the next one, whose
    -- dependents are tables only: without the flag, so its walk never
    -- reads the side table.
    local side = side_table()
    collect()
    collect()
    local n = count_entries(side)
    local s2 = enter("t.lt:20")
    held[4] = attach(new_logged(log, "y"), false, s2)
    test.assert_true(rawequal(rawget(s2, "deps"), list), "the list was reused")
    test.assert_eq(rawget(list, "other"), nil, "no flag on a reused list")
    exit(s2, "t.lt:22")
    test.assert_eq(log[#log], "y (anchor)")
    test.assert_eq(count_entries(side), n)
    for i, x in ipairs(held) do
        test.assert_false(alive(x), "held dependent " .. i)
    end
end)

test.case("No moves during destruction: an anchored function cannot be moved by a body, a new one can", function()
    local log = {}
    local b, c = {}, {}
    local old = attach(function()
    end, false, b)
    local results = {}
    local a = new_logged(log, "a", function()
        local ok, err = pcall(attach, old, false, c)
        results.old = ok or err
        local fresh = function()
        end
        results.fresh = pcall(attach, fresh, false, c)
        results.fresh_fn = fresh
    end)
    destroy(a)
    test.assert_eq(results.old, "attempt to move an anchored function during destruction")
    test.assert_true(results.fresh)
    test.assert_deep_eq(lifetime.dependents(c), {results.fresh_fn})
    test.assert_true(alive(old))
end)

test.case("a dying function cannot be moved: a destructor sees it dying", function()
    local log = {}
    local b = {}
    local f = function()
    end
    local result, seen
    local a = new_logged(log, "a", function()
        seen = alive(f)
        local ok, err = pcall(attach, f, false, b)
        result = ok or err
    end)
    attach(f, false, a)
    destroy(a)
    test.assert_true(seen, "dying is alive")
    test.assert_eq(result, "attempt to move a dying function")
    test.assert_false(alive(f))
    test.assert_deep_eq(lifetime.dependents(b), {})
end)

test.case("a body destroys a function dependent by hand, early; the later pass skips it", function()
    local log = {}
    local u
    local a = new_logged(log, "a", function()
        destroy(u)
        log[#log + 1] = "u alive: " .. tostring(alive(u))
    end)
    local x = attach(new_logged(log, "x"), false, a)
    u = attach(new_logged_userdata(log, "u"), false, a)
    destroy(a)
    test.assert_deep_eq(log, {"a (destroy)", "u (destroy)", "u alive: false", "x (anchor)"})
    test.assert_false(alive(x))
end)

test.case("__destroy on the shared metatable of functions and coroutines runs with the reason", function()
    local log = {}
    local names = {}
    local mt = {
        __destroy = function(obj, reason)
            log[#log + 1] = (names[obj] or "?") .. " (" .. reason .. ")"
        end
    }
    local f, g = function()
    end, function()
    end
    names[f], names[g] = "f", "g"
    local a = new_logged(log, "a")
    with_type_metatable(f, mt, function()
        attach(f, false, a)
        attach(g, false, a)
        destroy(a)
        destroy(attach(function()
        end, false, {}))
    end)
    test.assert_deep_eq(log, {"a (destroy)", "g (anchor)", "f (anchor)", "? (destroy)"})

    local co = coroutine.create(function()
    end)
    names[co] = "co"
    log = {}
    with_type_metatable(co, mt, function()
        destroy(co)
    end)
    test.assert_deep_eq(log, {"co (destroy)"})
end)

test.case("an error in a userdata's __destroy follows the cascade's error rule", function()
    local log = {}
    local a = new_logged(log, "a")
    local u = attach(new_logged_userdata(log, "u", function()
        error("u failed", 0)
    end), false, a)
    local x = attach(new_logged(log, "x", function()
        error("x failed", 0)
    end), false, a)
    local routed = {}
    local err
    with_handler(function(obj, e)
        routed[#routed + 1] = e
    end, function()
        local ok
        ok, err = pcall(destroy, a)
        test.assert_false(ok)
    end)
    test.assert_eq(err, "x failed", "the first error is raised at the destroy")
    test.assert_deep_eq(routed, {"u failed"}, "the second goes to destroyerror")
    test.assert_deep_eq(log, {"a (destroy)", "x (anchor)", "u (anchor)"})
    test.assert_false(alive(x))
    test.assert_false(alive(u))
end)

------------------------------------------------------------------------
test.suite("functions, coroutines, userdata: the collector")

test.case("case 5: a collected function's side entry goes with it, and its anchor's list has a hole", function()
    local side = side_table()
    local a = {}
    collect()
    collect()
    local before = count_entries(side)
    local probe = setmetatable({}, {__mode = "k"})
    run_dropped(function()
        local f = function()
        end
        probe[f] = true
        attach(f, false, a)
    end)
    test.assert_eq(count_entries(side), before + 1, "the record is in the side table")
    collect()
    collect()
    test.assert_eq(next(probe), nil, "the function was collected")
    test.assert_eq(count_entries(side), before, "its entry went with it")
    test.assert_deep_eq(lifetime.dependents(a), {})
end)

test.case("a dead function's record goes with it too", function()
    local side = side_table()
    collect()
    collect()
    local before = count_entries(side)
    run_dropped(function()
        local f = function()
        end
        destroy(attach(f, false, {}))
    end)
    test.assert_eq(count_entries(side), before + 1, "the death is remembered")
    collect()
    collect()
    test.assert_eq(count_entries(side), before)
end)

test.case("a dependent's reference to its anchor is strong: the anchor lives while the function does", function()
    -- docs/02-semantics.md, "Reachability is the collector's": "a
    -- dependent's reference to its anchor is strong, as any field would
    -- be"; docs/03-runtime.md: the side table's value "refers to the
    -- dependent's anchors". See the task file, "Spec issues found", for
    -- what this costs when the anchor refers back to the function.
    local log = {}
    local f = function()
    end
    run_dropped(function()
        attach(f, false, new_logged(log, "a"))
    end)
    collect()
    collect()
    test.assert_deep_eq(log, {}, "the anchor is reachable through f's record")
    test.assert_true(alive(f))
    run_dropped(function()
        attach(f, false, lifetime.reachable)
    end)
    test.assert_deep_eq(log, {})
    collect()
    test.assert_deep_eq(log, {"a (unreachable)"})
    test.assert_true(alive(f))
end)

test.case("known limitation: a pinned function and an anchor that nothing else holds are not collected", function()
    -- docs/02-semantics.md, "Reachability is the collector's": "A subtree
    -- nobody outside holds is therefore an ordinary cycle and dies as a
    -- whole when the collector finds its root". For a table dependent it
    -- does. For a function the edge to its anchor is the side table's
    -- value, and Lua 5.1 and LuaJIT mark the values of a weak-keyed table
    -- whether or not the key is reachable (no ephemerons): the anchor is
    -- held by the runtime while the function lives, and the function by
    -- the anchor's `strong` list. This pins what the runtime does; the
    -- task file, "Spec issues found", item 1, asks the human to choose.
    local log = {}
    local probe = setmetatable({}, {__mode = "k"})
    run_dropped(function()
        local a = new_logged(log, "a")
        local co = coroutine.create(function()
        end)
        probe[a], probe[co] = true, true
        attach(co, false, pin(a))
        -- The same shape with a table dependent, for comparison.
        local b = new_logged(log, "b")
        attach(new_logged(log, "t"), false, pin(b))
    end)
    collect()
    collect()
    collect()
    test.assert_deep_eq(log, {"b (unreachable)", "t (anchor)"}, "the table pair dies; the function pair does not")
    test.assert_eq(count_entries(probe), 2, "a and co are still there")
    -- `destroy` still works on them: here, through the anchor.
    for k in pairs(probe) do
        if type(k) == "table" then
            destroy(k)
        end
    end
    test.assert_deep_eq(log, {"b (unreachable)", "t (anchor)", "a (destroy)"})
    collect()
    collect()
    test.assert_eq(next(probe), nil, "dead, they are collected")
end)

test.case("compaction renumbers function dependents in the side table", function()
    -- docs/03-runtime.md, "The state of an object": compaction "renumbers
    -- the live entries densely from `lo`, in order, updates each
    -- dependent's stored sequence number". 80 dependents, tables and
    -- userdata in turn, of which 10 are held; then 50 held userdata: the
    -- range reaches its limit with more holes than live entries and is
    -- renumbered. The collector is stopped while the first 80 are made, so
    -- that the holes appear only at the collections below.
    local log, junk = {}, {}
    local a = new_logged(log, "a")
    local held = {}
    collectgarbage("stop")
    run_dropped(function()
        for i = 1, 80 do
            local dep
            if i % 2 == 0 then
                dep = new_logged_userdata(log, "u" .. i)
            else
                dep = new_logged(junk, "t" .. i)
            end
            attach(dep, false, a)
            if i % 16 == 1 or i % 16 == 4 then
                held[#held + 1] = dep
            end
        end
    end)
    collectgarbage("restart")
    collect()
    collect()
    test.assert_eq(#lifetime.dependents(a), 10)
    local deps = rawget(state_of(a), "deps")
    test.assert_eq(rawget(deps, "seq") - rawget(deps, "lo"), 80, "not compacted yet")
    for i = 81, 130 do
        held[#held + 1] = attach(new_logged_userdata(log, "u" .. i), false, a)
    end
    test.assert_true(rawget(deps, "seq") - rawget(deps, "lo") < 130, "compacted")
    test.assert_deep_eq(lifetime.dependents(a), held, "in attachment order")
    -- A userdata renumbered by the compaction leaves the right slot.
    local u4 = held[2]
    test.assert_eq(tostring(u4), "u4")
    attach(u4, false, {})
    local expected = {}
    for i = 1, #held do
        if i ~= 2 then
            expected[#expected + 1] = held[i]
        end
    end
    test.assert_deep_eq(lifetime.dependents(a), expected)
    test.assert_deep_eq(log, {})
    destroy(a)
    local order = {"a (destroy)"}
    for i = 130, 81, -1 do
        order[#order + 1] = "u" .. i .. " (anchor)"
    end
    for _, i in ipairs({68, 52, 36, 20}) do
        order[#order + 1] = "u" .. i .. " (anchor)"
    end
    test.assert_deep_eq(log, order)
    for _, dep in ipairs(expected) do
        test.assert_false(alive(dep))
    end
    test.assert_true(alive(u4))
end)

test.case("a userdata finalized by its own __gc never unlinks a slot compaction gave to another", function()
    -- A finalized userdata is cleared from weak values in the cycle that
    -- finalizes it, while its record stays in the weak-keyed side table
    -- for that cycle (docs/02-semantics.md, "Host"). Here `u2`'s `__gc`
    -- runs first (newest first) and links to `a` until a compaction
    -- renumbers its list, which gives `u1`'s old slot to `t1`; then
    -- `u1`'s `__gc` destroys `u1`, which must not unlink `t1`.
    local a = {}
    local held = {}
    run_dropped(function()
        local u1 = newproxy(true)
        getmetatable(u1).__gc = function(self)
            destroy(self)
        end
        attach(u1, false, a)
        for _ = 1, 14 do
            attach({}, false, a)
        end
        local u2 = newproxy(true)
        getmetatable(u2).__gc = function()
            for i = 1, 4 do
                held[i] = attach({}, false, a)
            end
        end
    end)
    collect()
    collect()
    test.assert_eq(#held, 4, "u2's finalizer ran")
    local deps = rawget(state_of(a), "deps")
    test.assert_true(rawget(deps, "seq") - rawget(deps, "lo") <= 4, "the list was compacted")
    test.assert_deep_eq(lifetime.dependents(a), held)
end)

test.case("a table dependent never touches the side table", function()
    local side = side_table()
    collect()
    collect()
    local before = count_entries(side)
    local log = {}
    local a = new_logged(log, "a")
    local held = {}
    for i = 1, 10 do
        held[i] = attach(new_logged(log, "x" .. i), false, a)
    end
    attach(held[1], false, held[2])
    test.assert_eq(count_entries(side), before)
    test.assert_eq(rawget(rawget(state_of(a), "deps"), "other"), nil, "no flag on an anchor of tables")
    destroy(a)
    test.assert_eq(count_entries(side), before)
    test.assert_eq(#log, 11)
end)

------------------------------------------------------------------------
test.suite("functions, coroutines, userdata: errors and follow-ups")

test.case("case 6: errors are positioned at the caller, never inside the runtime", function()
    local a = {}
    local dead = function()
    end
    destroy(dead)
    local raising = {
        function()
            attach({}, false, print)
        end,
        function()
            attach({}, false, coroutine.create(print))
        end,
        function()
            attach({}, false, newproxy())
        end,
        function()
            attach(dead, false, a)
        end,
        function()
            lifetime.of(dead)
        end,
        function()
            lifetime.format(dead)
        end,
        function()
            destroy(5)
        end,
        function()
            discard("s")
        end,
        function()
            lifetime.of(5)
        end,
        function()
            attach(function()
            end)
        end
    }
    for i, fn in ipairs(raising) do
        local ok, err = pcall(fn)
        test.assert_false(ok, "case " .. i .. " raises")
        test.assert_eq(err:sub(1, #THIS_FILE), THIS_FILE, "case " .. i .. ": " .. err)
        test.assert_eq(err:find("init.lua", 1, true), nil, "case " .. i .. ": " .. err)
    end
    test.assert_error(function()
        attach({}, false, print)
    end, "attempt to anchor to a function value")
    test.assert_error(function()
        attach({}, false, newproxy())
    end, "attempt to anchor to a userdata value")
    test.assert_error(function()
        attach(function()
        end)
    end, "bad argument #3 to 'lifetime.attach' (anchor expected, got no value)")

    -- What was a `not implemented` error is a destruction now: through
    -- `pcall` directly, the calls succeed.
    local f = function()
    end
    test.assert_deep_eq({pcall(destroy, f)}, {true})
    test.assert_false(alive(f))
    local ok, v = pcall(lifetime.of, function()
    end)
    test.assert_true(ok)
    test.assert_true(rawequal(v, lifetime.reachable))
end)

test.case("the default destroyerror flushes standard output before writing its report", function()
    local output = run_merged([[
local lifetime = require("lifetime")
print("before")
local t = setmetatable({}, {__destroy = function()
    error("t failed", 0)
end})
lifetime.attach(t, false, lifetime.reachable)
t = nil
collectgarbage("collect")
print("after")
]])
    local before = output:find("before\n", 1, true)
    local report = output:find("destroyerror: t failed", 1, true)
    local after = output:find("after\n", 1, true)
    test.assert_true(before ~= nil and report ~= nil and after ~= nil, output)
    test.assert_true(before < report, "the report comes after what was printed before it: " .. output)
    test.assert_true(report < after, output)
end)

test.case("the fallback report of a failing destroyerror flushes standard output too", function()
    local output = run_merged([[
local lifetime = require("lifetime")
destroyerror = function()
    error("handler failed", 0)
end
print("before")
local t = setmetatable({}, {__destroy = function()
    error("t failed", 0)
end})
lifetime.attach(t, false, lifetime.reachable)
t = nil
collectgarbage("collect")
print("after")
]])
    local before = output:find("before\n", 1, true)
    local report = output:find("destroyerror: t failed\ndestroyerror: error in destroyerror (handler failed)", 1, true)
    local after = output:find("after\n", 1, true)
    test.assert_true(before ~= nil and report ~= nil and after ~= nil, output)
    test.assert_true(before < report and report < after, output)
end)

test.case("a coroutine.wrap error reads as the standalone interpreter's; LuaJIT shows no runtime frame", function()
    -- The program has the same lines with and without the runtime.
    local source = [[
local w = coroutine.wrap(function()
    error("boom")
end)
w()
]]
    local plain, plain_script = run_merged("local _ = nil\n" .. source)
    local with_runtime, runtime_script = run_merged("require('lifetime')\n" .. source)
    local function first_line(output, script)
        local line = output:match("^[^\n]*")
        local from, to = line:find(script, 1, true)
        while from do
            line = line:sub(1, from - 1) .. "SCRIPT" .. line:sub(to + 1)
            from, to = line:find(script, 1, true)
        end
        return line
    end
    test.assert_true(first_line(plain, plain_script):find("SCRIPT:6: SCRIPT:4: boom", 1, true) ~= nil, plain)
    test.assert_eq(first_line(with_runtime, runtime_script), first_line(plain, plain_script))
    if jit then
        test.assert_eq(with_runtime:find("init.lua", 1, true), nil, with_runtime)
        test.assert_true(with_runtime:find("[C]: in function 'w'", 1, true) ~= nil, with_runtime)
    end

    -- What `pcall` returns is unchanged: the position of the wrap
    -- function's caller, then the coroutine's own message.
    local line
    local ok, err = pcall(function()
        local w = coroutine.wrap(function()
            error("inner", 0)
        end)
        line = debug.getinfo(1, "l").currentline + 1
        w()
    end)
    test.assert_false(ok)
    test.assert_eq(err, THIS_FILE .. ":" .. line .. ": inner")
    local e = {}
    ok, err = pcall(coroutine.wrap(function()
        error(e)
    end))
    test.assert_false(ok)
    test.assert_true(rawequal(err, e), "a table is re-raised as it is")
end)
