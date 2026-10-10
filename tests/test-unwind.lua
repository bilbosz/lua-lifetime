-- tests/test-unwind.lua: lifetime/init.lua, task 014. The runtime's
-- `pcall` and `xpcall` unwind the scope records pushed since the call
-- began from a message handler, at the raise point, while the frames
-- that raised are still on the stack (docs/02-semantics.md, "Scopes:
-- `lifetime.scope`"; docs/03-runtime.md, "The scope stack and the error
-- path"; docs/05-decisions.md, "Scopes unwind at the raise point").
--
-- The tests write the block prologue and epilogue by hand, as generated
-- code would (docs/04-transpiler.md, "Blocks"), and compare whole logs of
-- deaths with their reasons, before and after the statement that caused
-- them (CLAUDE.md, rule 3). Deaths by `reachable` are pinned with
-- `collectgarbage("collect")`, twice where a weak table must clear.
local test = require("tests.lib.test")
local lifetime = require("lifetime")
local conformance = require("tests.conformance")

local attach, enter, exit = lifetime.attach, lifetime.enter, lifetime.exit

-- Whether this host's `xpcall` passes arguments to `f` (LuaJIT) or not
-- (Lua 5.1): what a few cases record per host.
local LUAJIT = rawget(_G, "jit") ~= nil

-- A logging object: `__tostring` gives `name`, `__destroy` appends
-- `name (reason)` to `log`, and `extra(self, reason)` runs inside the body
-- after it logs, when given.
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

-- Holds `x` for the rest of the suite and returns it, where the test's
-- own frame cannot (CLAUDE.md, rule 6: "If a test needs a strong
-- reference to keep an object alive, the test holds it").
local held = {}
local function hold(x)
    held[#held + 1] = x
    return x
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
-- upvalues").
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
    local ok, err = hidden_pcall(fn)
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
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

-- Run `command` with `sh -c`, from the repository root; returns its
-- standard output, standard error and exit status (as tests/conformance.lua
-- runs an example: through files, which both hosts' `os.execute` allow).
local function run_shell(command)
    local out, err, status = os.tmpname(), os.tmpname(), os.tmpname()
    os.execute(string.format("sh -c %s >%s 2>%s; echo $? >%s", shell_quote(command), shell_quote(out), shell_quote(err), shell_quote(status)))
    local stdout, stderr = read_file(out) or "", read_file(err) or ""
    local code = tonumber((read_file(status) or ""):match("%d+")) or -1
    os.remove(out)
    os.remove(err)
    os.remove(status)
    return stdout, stderr, code
end

-- Run `source` as a fresh program under the interpreter running this
-- suite, from the repository root; returns its standard output and
-- standard error.
local function run_program(source)
    local interpreter = arg and arg[-1] or "lua5.1"
    local script = os.tmpname()
    local f = assert(io.open(script, "wb"))
    f:write("package.path = './?.lua;./?/init.lua;' .. package.path\n", source)
    f:close()
    local stdout, stderr = run_shell(shell_quote(interpreter) .. " " .. shell_quote(script))
    os.remove(script)
    return stdout, stderr
end

------------------------------------------------------------------------
test.suite("unwind: at the raise point")

-- Test case 1. The collector parameters of task 008's spec issue 5, set in
-- the child through `LUA_INIT`, which both standalone interpreters run
-- before the script. Before task 014, Lua 5.1 printed `destroy a
-- (unreachable)` instead of `destroy a (anchor)`: `a` was referred to by
-- a frame the catch-site unwinding ran after.
local STRESS = "collectgarbage(\"setpause\",10) collectgarbage(\"setstepmul\",1000)"

for _, interpreter in ipairs(conformance.find_interpreters()) do
    test.case("case 1: examples/unwind.lt prints its .expected under a stressed collector (" .. interpreter .. ")", function()
        local env = "LUA_INIT=" .. shell_quote(STRESS) .. " "
        -- The stress reached the child: `setpause` returns the previous
        -- pause, 10 when LUA_INIT has set it (200 by default).
        local pause = run_shell(env .. interpreter .. " -e " .. shell_quote("io.write(collectgarbage('setpause', 10))"))
        test.assert_eq(pause, "10", "LUA_INIT reached the child")
        local expected_stdout, expected_error = conformance.parse_expected(assert(read_file("examples/unwind.lt.expected")))
        test.assert_eq(expected_error, "examples/unwind.lt:101: uncaught")
        test.assert_eq(expected_stdout:match("^[^\n]*\n[^\n]*\n[^\n]*\n"), "destroy b (anchor)\ndestroy a (anchor)\npcall returned\tfalse\texamples/unwind.lt:27: boom\n")
        local stdout, stderr, status = run_shell(env .. interpreter .. " bin/lifetime run examples/unwind.lt")
        test.assert_eq(stdout, expected_stdout)
        test.assert_eq(status, 1)
        test.assert_eq(conformance.reported_error(stderr), expected_error)
    end)
end

test.case("case 2: a dependent held only by a local of the raising frame is alive until its own destructor runs", function()
    -- The sentence most likely to be misread (docs/02-semantics.md,
    -- "Scopes": "a dependent of an unwound scope is reachable until its
    -- own destructor runs and the collector cannot take it first"). With
    -- the catch-site runtime the log was {"b (anchor)", "a (unreachable)"}:
    -- the two collections inside b's destructor took a, whose frame was
    -- gone.
    local log = {}
    local before = depth()
    local ok, err = pcall(function()
        local outer = enter("t.lt:20")
        local a = attach(new_logged(log, "a"), false, outer) -- luacheck: ignore a
        local inner = enter("t.lt:18")
        local b = attach(new_logged(log, "b", function() -- luacheck: ignore b
            collectgarbage("collect")
            collectgarbage("collect")
        end), false, inner)
        error("boom", 0)
    end)
    test.assert_false(ok)
    test.assert_eq(err, "boom")
    test.assert_deep_eq(log, {"b (anchor)", "a (anchor)"})
    test.assert_eq(depth(), before)
end)

test.case("case 2: the same through pcall with an argument and through xpcall", function()
    local function body(log)
        local outer = enter("t.lt:30")
        local a = attach(new_logged(log, "a"), false, outer) -- luacheck: ignore a
        local inner = enter("t.lt:29")
        local b = attach(new_logged(log, "b", function() -- luacheck: ignore b
            collectgarbage("collect")
            collectgarbage("collect")
        end), false, inner)
        error("boom", 0)
    end
    local log = {}
    local ok, err = pcall(body, log)
    test.assert_false(ok)
    test.assert_eq(err, "boom")
    test.assert_deep_eq(log, {"b (anchor)", "a (anchor)"})
    local xlog = {}
    ok, err = xpcall(function()
        body(xlog)
    end, function(m)
        xlog[#xlog + 1] = "handler " .. m
        return m
    end)
    test.assert_false(ok)
    test.assert_eq(err, "boom")
    test.assert_deep_eq(xlog, {"handler boom", "b (anchor)", "a (anchor)"})
end)

test.case("case 3: a user xpcall handler runs before any record is unwound; its result is the error value", function()
    local log = {}
    local before = depth()
    local ok, err = xpcall(function()
        local s = enter("t.lt:30")
        hold(attach(new_logged(log, "x"), false, s))
        error("boom", 0)
    end, function(m)
        log[#log + 1] = "handler " .. m
        return "handled"
    end)
    test.assert_false(ok)
    test.assert_eq(err, "handled")
    test.assert_deep_eq(log, {"handler boom", "x (anchor)"})
    test.assert_eq(depth(), before)
end)

test.case("case 3b: a user handler that raises gives error in error handling, the records unwound all the same", function()
    local log = {}
    local calls = 0
    local before = depth()
    local ok, err = xpcall(function()
        local s = enter("t.lt:30")
        hold(attach(new_logged(log, "x"), false, s))
        error("boom", 0)
    end, function()
        calls = calls + 1
        error("in handler", 0)
    end)
    test.assert_false(ok)
    test.assert_eq(err, "error in error handling")
    test.assert_deep_eq(log, {"x (anchor)"})
    test.assert_eq(depth(), before)
    -- Called once; the original Lua 5.1 xpcall calls a raising handler
    -- again for each level of the C stack (the task file, "Spec issues
    -- found").
    test.assert_eq(calls, 1)
end)

test.case("case 3b: a handler that is not callable gives error in error handling (Lua 5.1) or the host's argument error (LuaJIT)", function()
    local log = {}
    local function body()
        local s = enter("t.lt:35")
        hold(attach(new_logged(log, "x"), false, s))
        error("boom", 0)
    end
    if LUAJIT then
        -- LuaJIT's xpcall refuses a handler that is not a function before
        -- it calls anything.
        test.assert_error(function()
            xpcall(body, 5)
        end, "bad argument #2 to 'xpcall'")
        test.assert_deep_eq(log, {})
    else
        local ok, err = xpcall(body, 5)
        test.assert_false(ok)
        test.assert_eq(err, "error in error handling")
        test.assert_deep_eq(log, {"x (anchor)"})
        ok, err = xpcall(body, nil)
        test.assert_false(ok)
        test.assert_eq(err, "error in error handling")
        test.assert_deep_eq(log, {"x (anchor)", "x (anchor)"})
    end
end)

test.case("case 4: an error value that is not a string comes out unchanged", function()
    local log = {}
    local e = {}
    local ok, got = pcall(function()
        local s = enter("t.lt:40")
        hold(attach(new_logged(log, "x"), false, s))
        error(e)
    end)
    test.assert_false(ok)
    test.assert_true(rawequal(got, e), "the same table")
    test.assert_deep_eq(log, {"x (anchor)"})
    test.assert_eq(select("#", pcall(error)), 2)
    test.assert_eq(select(2, pcall(error)), nil)
    -- `error(42)` adds the position of level 1, which under `pcall` is a C
    -- function and so empty, and Lua turns the number into a string
    -- doing it: both hosts' originals return `"42"` (the task file, "Spec
    -- issues found"). With level 0 the number stays a number.
    ok, got = pcall(error, 42)
    test.assert_false(ok)
    test.assert_eq(got, select(2, hidden_pcall(error, 42)))
    test.assert_eq(type(got), "string")
    ok, got = pcall(error, 42, 0)
    test.assert_false(ok)
    test.assert_eq(type(got), "number")
    test.assert_eq(got, 42)
    ok, got = xpcall(function()
        error(e)
    end, function(m)
        return m
    end)
    test.assert_false(ok)
    test.assert_true(rawequal(got, e), "the same table through a user handler")
    -- A number raised with level 0 stays a number through the handlers.
    ok, got = pcall(function()
        local s = enter("t.lt:45")
        hold(attach(new_logged(log, "y"), false, s))
        error(7, 0)
    end)
    test.assert_false(ok)
    test.assert_eq(type(got), "number")
    test.assert_deep_eq(log, {"x (anchor)", "y (anchor)"})
end)

test.case("case 5: pcall passes every argument, trailing nils included", function()
    local n
    local function count(...)
        n = select("#", ...)
        local a, b, c = ...
        return c, b, a
    end
    local ok, r1, r2, r3 = pcall(count, 1, nil, 3)
    test.assert_true(ok)
    test.assert_eq(n, 3)
    test.assert_eq(r1, 3)
    test.assert_eq(r2, nil)
    test.assert_eq(r3, 1)
    test.assert_eq(select("#", pcall(count, 1, nil, 3)), 4)
    pcall(count, nil)
    test.assert_eq(n, 1)
    pcall(count)
    test.assert_eq(n, 0)
    pcall(count, nil, nil)
    test.assert_eq(n, 2)
    pcall(count, 1, 2, 3, nil)
    test.assert_eq(n, 4)
    pcall(count, 1, 2, 3, 4, 5, 6, 7, 8)
    test.assert_eq(n, 8)
    pcall(count, 1, nil, nil, nil, nil, nil, nil, nil, nil)
    test.assert_eq(n, 9)
    test.assert_deep_eq({pcall(count, "a", "b")}, {true, nil, "b", "a"})
    -- Through xpcall where the host passes arguments (LuaJIT); Lua 5.1's
    -- xpcall passes none, as the original does.
    xpcall(count, print, 1, nil)
    test.assert_eq(n, LUAJIT and 2 or 0)
end)

test.case("case 5: a function given arguments has the records it pushed unwound at the raise point", function()
    local log = {}
    local before = depth()
    local function body(a, b, c, d)
        local s = enter("t.lt:50")
        hold(attach(new_logged(log, a), false, s))
        local inner = enter("t.lt:49")
        hold(attach(new_logged(log, b), false, inner))
        log[#log + 1] = "raise " .. tostring(c) .. " " .. tostring(d)
        error("boom", 0)
    end
    test.assert_deep_eq({pcall(body, "x", "y")}, {false, "boom"})
    test.assert_deep_eq({pcall(body, "x", "y", 3)}, {false, "boom"})
    test.assert_deep_eq({pcall(body, "x", "y", 3, 4)}, {false, "boom"})
    test.assert_deep_eq(log, {"raise nil nil", "y (anchor)", "x (anchor)", "raise 3 nil", "y (anchor)", "x (anchor)", "raise 3 4", "y (anchor)", "x (anchor)"})
    test.assert_eq(depth(), before)
end)

test.case("case 6: a destructor error during the unwinding goes to destroyerror; the call's own value comes out", function()
    local log, routed = {}, {}
    local x
    local ok, err
    local function record(obj, e)
        routed[#routed + 1] = tostring(obj) .. ": " .. e
    end
    with_handler(record, function()
        ok, err = xpcall(function()
            local s = enter("t.lt:60")
            x = hold(attach(new_logged(log, "x", function()
                error("x failed", 0)
            end), false, s))
            error("boom", 0)
        end, function(m)
            return "handled " .. m
        end)
    end)
    test.assert_false(ok)
    test.assert_eq(err, "handled boom")
    test.assert_deep_eq(log, {"x (anchor)"})
    test.assert_deep_eq(routed, {"x: x failed"})
    test.assert_false(lifetime.alive(x))
    with_handler(record, function()
        ok, err = pcall(function()
            local s = enter("t.lt:65")
            hold(attach(new_logged(log, "y", function()
                error("y failed", 0)
            end), false, s))
            error("boom", 0)
        end)
    end)
    test.assert_false(ok)
    test.assert_eq(err, "boom")
    test.assert_deep_eq(log, {"x (anchor)", "y (anchor)"})
    test.assert_deep_eq(routed, {"x: x failed", "y: y failed"})
end)

test.case("case 7: a stack overflow inside a protected call; every record dies once, innermost first", function()
    -- docs/02-semantics.md, "Scopes": "One error keeps no order: a stack
    -- overflow." Plain Lua recursion, never an infinite `__index` chain
    -- (which crashes LuaJIT itself).
    --
    -- What each host did when this was written (2026-10-10):
    -- * Lua 5.1 refills the Lua stack for the message handler: the
    --   handler unwinds every record before `pcall` returns, `err` is the
    --   overflow message.
    -- * LuaJIT leaves the handler about a dozen small frames: the handler
    --   finds no room (lifetime/init.lua, `unwind_at_raise`), unwinds
    --   nothing, and the records stay on the stack; `after`, entered on
    --   top of them, exits without touching them (they are below it), and
    --   the exit of `outer` finds them above itself and unwinds them,
    --   innermost first, before its own (02: "A record that a catch the
    --   runtime could not see left behind dies at the next scope exit of
    --   the same coroutine that finds it above itself"). The task's test
    --   case 7 exits only `after`, which cannot find them; the enclosing
    --   `outer` is this test's (the task file, "Spec issues found").
    -- The overflow can strike inside `attach`, before or after the object
    -- is linked: the greatest `n` is read from the log, not counted.
    local log, routed = {}, {}
    local attached = 0
    local before = depth()
    local function deep(n)
        local s = enter("t.lt:70")
        hold(attach(new_logged(log, tostring(n)), false, s))
        attached = n
        local r = 1 + deep(n + 1)
        exit(s, "t.lt:70")
        return r
    end
    local ok, err, log_at_return
    local outer = enter("t.lt:90")
    with_handler(function(_, e)
        routed[#routed + 1] = e
    end, function()
        ok, err = pcall(deep, 1)
        log_at_return = #log
        local after = enter("t.lt:80")
        exit(after, "t.lt:80")
        test.assert_eq(#log, log_at_return, "the exit of `after` unwinds nothing below it")
        exit(outer, "t.lt:90")
    end)
    test.assert_false(ok)
    test.assert_true(type(err) == "string" and (err:find("stack overflow", 1, true) or err == "error in error handling"), tostring(err))
    local greatest = tonumber(log[1] and log[1]:match("^(%d+) "))
    test.assert_true(greatest ~= nil and greatest >= attached and greatest <= attached + 1, "greatest " .. tostring(greatest) .. ", attached " .. attached)
    test.assert_eq(#log, greatest)
    local wrong = {}
    for i = 1, #log do
        if log[i] ~= (greatest - i + 1) .. " (anchor)" then
            wrong[#wrong + 1] = i .. ": " .. log[i]
            if #wrong > 5 then
                break
            end
        end
    end
    test.assert_deep_eq(wrong, {}, "decreasing from the greatest to 1, each once, reason anchor")
    for _, e in ipairs(routed) do
        test.assert_true(tostring(e):find("stack overflow", 1, true) or e == "error in error handling", tostring(e))
    end
    if LUAJIT then
        test.assert_eq(log_at_return, 0, "LuaJIT: the handler found no room and left the records")
    else
        test.assert_eq(log_at_return, greatest, "Lua 5.1: the handler unwound every record")
    end
    test.assert_eq(depth(), before)
    -- The runtime goes on: a block owning an object, then an error
    -- through a scoped block.
    local s = enter("t.lt:95")
    hold(attach(new_logged(log, "later"), false, s))
    exit(s, "t.lt:95")
    test.assert_eq(log[#log], "later (anchor)")
    test.assert_deep_eq({pcall(function()
        local r = enter("t.lt:96")
        hold(attach(new_logged(log, "last"), false, r))
        error("x", 0)
    end)}, {false, "x"})
    test.assert_eq(log[#log], "last (anchor)")
end)

------------------------------------------------------------------------
test.suite("unwind: which records, which handler")

test.case("the handler unwinds only what the innermost protected call pushed, the enclosing records later", function()
    local log = {}
    local before = depth()
    local ok, err = pcall(function()
        local s1 = enter("t.lt:100")
        hold(attach(new_logged(log, "s1"), false, s1))
        local ok2, err2 = pcall(function()
            local s2 = enter("t.lt:101")
            hold(attach(new_logged(log, "s2"), false, s2))
            error("inner", 0)
        end)
        log[#log + 1] = "inner returned " .. tostring(ok2) .. " " .. err2
        error("outer", 0)
    end)
    test.assert_false(ok)
    test.assert_eq(err, "outer")
    test.assert_deep_eq(log, {"s2 (anchor)", "inner returned false inner", "s1 (anchor)"})
    test.assert_eq(depth(), before)
end)

test.case("a protected call that returned inside a block leaves nothing behind: the block's record dies with the enclosing call", function()
    -- The inner call began at depth before + 1 and returned; the error
    -- after it belongs to the outer call, which began at `before`.
    local log = {}
    local before = depth()
    local ok = pcall(function()
        local s1 = enter("t.lt:110")
        hold(attach(new_logged(log, "s1"), false, s1))
        test.assert_true(pcall(function()
            return 1
        end))
        test.assert_true(pcall(function(a)
            return a
        end, 1))
        test.assert_true(xpcall(function()
            return 1
        end, print))
        error("after", 0)
    end)
    test.assert_false(ok)
    test.assert_deep_eq(log, {"s1 (anchor)"})
    test.assert_eq(depth(), before)
end)

test.case("records of an enclosing block outside the call stay; an error with none pushed unwinds nothing", function()
    local log = {}
    local outside = enter("t.lt:120")
    local keep = attach(new_logged(log, "outside"), false, outside)
    test.assert_deep_eq({pcall(error, "x", 0)}, {false, "x"})
    test.assert_deep_eq({pcall(function()
        error("y", 0)
    end)}, {false, "y"})
    test.assert_deep_eq({xpcall(function()
        error("z", 0)
    end, function(m)
        return m
    end)}, {false, "z"})
    test.assert_deep_eq(log, {})
    test.assert_true(lifetime.alive(keep))
    exit(outside, "t.lt:120")
    test.assert_deep_eq(log, {"outside (anchor)"})
end)

test.case("xpcall: a nested call's handler is put back; the outer call's handler runs for the outer error", function()
    local log = {}
    local ok, err = xpcall(function()
        local s = enter("t.lt:130")
        hold(attach(new_logged(log, "outer x"), false, s))
        local ok2, err2 = xpcall(function()
            local r = enter("t.lt:131")
            hold(attach(new_logged(log, "inner y"), false, r))
            error("inner", 0)
        end, function(m)
            log[#log + 1] = "h2 " .. m
            return "h2"
        end)
        log[#log + 1] = "inner returned " .. tostring(ok2) .. " " .. err2
        test.assert_true(xpcall(function()
            return 1
        end, function()
            log[#log + 1] = "h3 must not run"
        end))
        error("outer", 0)
    end, function(m)
        log[#log + 1] = "h1 " .. m
        return "h1"
    end)
    test.assert_false(ok)
    test.assert_eq(err, "h1")
    test.assert_deep_eq(log, {"h2 inner", "inner y (anchor)", "inner returned false h2", "h1 outer", "outer x (anchor)"})
end)

test.case("a handler that calls xpcall itself, and a destructor run by the unwinding that uses pcall", function()
    local log = {}
    local ok, err = xpcall(function()
        local s = enter("t.lt:140")
        hold(attach(new_logged(log, "x", function()
            local ok2, err2 = pcall(function()
                local r = enter("t.lt:141")
                hold(attach(new_logged(log, "in destructor"), false, r))
                error("d", 0)
            end)
            log[#log + 1] = "destructor's pcall " .. tostring(ok2) .. " " .. err2
        end), false, s))
        error("boom", 0)
    end, function(m)
        local ok3, err3 = xpcall(function()
            error("h", 0)
        end, function(m3)
            return "inner " .. m3
        end)
        log[#log + 1] = "handler's xpcall " .. tostring(ok3) .. " " .. err3
        return "handled " .. m
    end)
    test.assert_false(ok)
    test.assert_eq(err, "handled boom")
    -- What the host gives an xpcall that fails inside a message handler
    -- (the user's `h` runs under the host's in-handler mark, as under the
    -- host's own xpcall): `inner h` on Lua 5.1. LuaJIT counts the inner
    -- error as an error in the outer handler, `error in error handling`,
    -- when its interpreter raises it, but gives `inner h` when the inner
    -- raise runs on a compiled trace (the task file, round 2, F2: about 2
    -- runs in 200 with no runtime loaded), so either is the host's.
    if LUAJIT then
        test.assert_true(log[1] == "handler's xpcall false error in error handling" or log[1] == "handler's xpcall false inner h", log[1])
    else
        test.assert_eq(log[1], "handler's xpcall false inner h")
    end
    test.assert_deep_eq({log[2], log[3], log[4], log[5]}, {"x (anchor)", "in destructor (anchor)", "destructor's pcall false d", nil})
    test.assert_eq(#log, 4)
end)

-- Round 2, F1: a destructor that the handler's unwinding runs may make a
-- protected call of its own, which must call its handler as anywhere
-- else. LuaJIT refuses to run a message handler while one runs, until a
-- throw resets its mark; the runtime resets it before it unwinds
-- (lifetime/init.lua, `unwind_at_raise`). Both programs run through
-- `pcall` and through `xpcall` with an `h` that returns normally.
local function protected_in_destructor(call, log)
    local keep = {}
    local ok, e = call(function()
        local s = enter("t:10")
        keep[1] = attach(new_logged(log, "x", function()
            local ok2, e2 = pcall(function()
                error("d", 0)
            end)
            log[#log + 1] = "x's pcall: " .. tostring(ok2) .. " " .. tostring(e2)
        end), false, s)
        error("boom", 0)
    end)
    log[#log + 1] = "outer: " .. tostring(ok) .. " " .. tostring(e)
    ok, e = call(function()
        local s = enter("t:20")
        keep[2] = attach(new_logged(log, "y", function()
            local ok2, e2 = pcall(function()
                local r = enter("t:21")
                keep[3] = attach(new_logged(log, "inner"), false, r)
                error("d4", 0)
            end)
            log[#log + 1] = "y's pcall with record: " .. tostring(ok2) .. " " .. tostring(e2)
        end), false, s)
        error("boom", 0)
    end)
    log[#log + 1] = "outer: " .. tostring(ok) .. " " .. tostring(e)
    return keep
end

test.case("F1: a destructor run by the unwinding of pcall makes protected calls that call their handlers", function()
    local log = {}
    local before = depth()
    protected_in_destructor(pcall, log)
    test.assert_deep_eq(log, {
        "x (anchor)", "x's pcall: false d", "outer: false boom",
        "y (anchor)", "inner (anchor)", "y's pcall with record: false d4", "outer: false boom"
    })
    test.assert_eq(depth(), before)
end)

test.case("F1: the same through xpcall with a handler that returns normally", function()
    local log = {}
    local before = depth()
    protected_in_destructor(function(f)
        return xpcall(f, function(m)
            log[#log + 1] = "h " .. m
            return m
        end)
    end, log)
    test.assert_deep_eq(log, {
        "h boom", "x (anchor)", "x's pcall: false d", "outer: false boom",
        "h boom", "y (anchor)", "inner (anchor)", "y's pcall with record: false d4", "outer: false boom"
    })
    test.assert_eq(depth(), before)
end)

test.case("F1: a destructor's xpcall and pcall with arguments during the unwinding", function()
    local log = {}
    local ok, e = pcall(function()
        local s = enter("t:30")
        hold(attach(new_logged(log, "x", function()
            local xok, xerr = xpcall(function()
                error("d", 0)
            end, function(m)
                return "handled " .. m
            end)
            log[#log + 1] = "xpcall " .. tostring(xok) .. " " .. tostring(xerr)
            -- The call runs before the slot of `log` is chosen.
            local _, got = pcall(function(a, b)
                local r = enter("t:31")
                hold(attach(new_logged(log, "inner " .. a), false, r))
                error(b, 0)
            end, "a", "b")
            log[#log + 1] = "pcall with arguments " .. tostring(got)
        end), false, s))
        error("boom", 0)
    end)
    test.assert_false(ok)
    test.assert_eq(e, "boom")
    test.assert_deep_eq(log, {"x (anchor)", "xpcall false handled d", "inner a (anchor)", "pcall with arguments b"})
end)

test.case("in a coroutine the handler unwinds the coroutine's own stack", function()
    local log = {}
    local main_before = depth()
    local co = coroutine.create(function()
        local s = enter("t.lt:150")
        hold(attach(new_logged(log, "co s"), false, s))
        local ok, err = pcall(function()
            local r = enter("t.lt:151")
            hold(attach(new_logged(log, "co r"), false, r))
            coroutine.yield("first")
            error("boom", 0)
        end)
        log[#log + 1] = "pcall " .. tostring(ok) .. " " .. tostring(err)
        coroutine.yield("second")
        exit(s, "t.lt:150")
    end)
    local supports_yield = LUAJIT
    local ok, v = coroutine.resume(co)
    if not supports_yield then
        -- Lua 5.1 cannot yield across pcall: the yield raises inside it,
        -- and the handler unwinds `co r` all the same.
        test.assert_true(ok)
        test.assert_eq(v, "second")
        test.assert_eq(log[1], "co r (anchor)")
        test.assert_true(log[2]:find("^pcall false .*yield across") ~= nil, log[2])
    else
        test.assert_true(ok)
        test.assert_eq(v, "first")
        test.assert_deep_eq(log, {})
        ok, v = coroutine.resume(co)
        test.assert_true(ok)
        test.assert_eq(v, "second")
        test.assert_deep_eq(log, {"co r (anchor)", "pcall false boom"})
    end
    test.assert_eq(depth(), main_before, "the main stack is untouched")
    test.assert_true(coroutine.resume(co))
    test.assert_eq(log[#log], "co s (anchor)")
end)

test.case("LuaJIT: two coroutines yield inside xpcall in turn; each error goes to its own handler", function()
    if not LUAJIT then
        -- Lua 5.1 cannot yield across xpcall; nothing to interleave.
        return
    end
    local log = {}
    local function body(name)
        return function()
            return xpcall(function()
                local s = enter("t.lt:160")
                hold(attach(new_logged(log, name .. " x"), false, s))
                coroutine.yield()
                error(name, 0)
            end, function(m)
                log[#log + 1] = "handler of " .. name .. ": " .. m
                return name .. " handled"
            end)
        end
    end
    local a, b = coroutine.create(body("a")), coroutine.create(body("b"))
    test.assert_true(coroutine.resume(a))
    test.assert_true(coroutine.resume(b))
    test.assert_deep_eq({coroutine.resume(a)}, {true, false, "a handled"})
    test.assert_deep_eq({coroutine.resume(b)}, {true, false, "b handled"})
    test.assert_deep_eq(log, {"handler of a: a", "a x (anchor)", "handler of b: b", "b x (anchor)"})
end)

------------------------------------------------------------------------
test.suite("unwind: what the originals do")

-- A fresh program calls each protected call through the original, then
-- requires `lifetime` and calls it again through the replacement, from
-- the same call sites, and prints `label<TAB>ok` or the two results.
--
-- The calls marked `POSITIONAL` raise an error whose position is that of
-- the protected call's caller: the original's own argument error (level
-- 1 seen from it) and `error(m, 2)` given to it. On Lua 5.1 the
-- replacement calls the original from its own frame, which a C function
-- entered from Lua runs above, so that position is the wrapper's; the
-- catch-site runtime of task 003 did the same, and this task does not
-- change it (the task file, "Spec issues found"). There the program
-- compares those messages without their position. LuaJIT replaces the
-- wrapper's frame and gives the caller's.
local COMPARE = [==[
local orig_pcall = pcall
local NORMALISE = jit == nil
local function pack(positional, ...)
    local t = {select("#", ...)}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if positional and NORMALISE and type(v) == "string" then
            v = v:gsub("^[^:]*:%d+: ", "")
        end
        t[#t + 1] = type(v) .. ":" .. tostring(v)
    end
    return table.concat(t, ",")
end
local POSITIONAL = {[1] = true, [2] = true, [3] = true, [5] = true}
local function lua_level2(m) error(m, 2) end
local function lua_level1(m) error(m) end
local callable = setmetatable({}, {__call = function(self, a, b) return a, b end})
local calls = {
    function() return pcall() end,
    function() return xpcall() end,
    function() return xpcall(print) end,
    function() return pcall(error, "caught") end,
    function() return pcall(error, "m", 2) end,
    function() return pcall(error) end,
    function() return pcall(string.rep) end,
    function() return pcall(string.rep, {}) end,
    function() return pcall(string.rep, "x", "y") end,
    function() return pcall(assert, false, "message") end,
    function() return pcall(assert, false) end,
    function() return pcall(setmetatable, 1, 2) end,
    function() return pcall(select, "#", 1, nil) end,
    function() return pcall(tostring, nil) end,
    function() return pcall(nil, 1) end,
    function() return pcall(5, 1, 2) end,
    function() return pcall({}, 1) end,
    function() return pcall(callable, 1, nil) end,
    function() return pcall(lua_level2, "two") end,
    function() return pcall(lua_level2, "two", 1, 2, 3, 4) end,
    function() return pcall(lua_level1, "one") end,
    function() return pcall(function(...) return select("#", ...), ... end, nil, nil) end,
    function() return xpcall(error, function(m) return "h:" .. tostring(m) end) end,
    function() return xpcall(function() error({}) end, type) end,
    function() return xpcall(function() return 1, nil end, print) end,
}
local results = {}
for i, call in ipairs(calls) do
    results[i] = pack(POSITIONAL[i], orig_pcall(call))
end
require("lifetime")
for i, call in ipairs(calls) do
    local now = pack(POSITIONAL[i], orig_pcall(call))
    print(i .. "\t" .. (now == results[i] and "ok" or (results[i] .. " | " .. now)))
end
]==]

test.case("argument errors, C functions given arguments and Lua functions' levels come out as from the originals", function()
    -- docs/03-runtime.md: the protected call "returns what the original
    -- `xpcall` returned"; the task's acceptance criterion on argument
    -- errors. A C function given arguments goes to the original `pcall` on
    -- Lua 5.1 (lifetime/init.lua, "Only a Lua function is carried").
    local out, err = run_program(COMPARE)
    test.assert_eq(err, "")
    local lines, bad = 0, {}
    for line in out:gmatch("[^\n]+") do
        lines = lines + 1
        if not line:find("\tok$") then
            bad[#bad + 1] = line
        end
    end
    test.assert_eq(lines, 25, out)
    test.assert_deep_eq(bad, {})
end)

test.case("Lua 5.1: a C function given arguments has the records its callbacks pushed unwound when the original pcall returns", function()
    -- The catch site that remains on Lua 5.1 (the task file, "Spec issues
    -- found"): the order and reasons are those of the raise point.
    local log = {}
    local before = depth()
    local t = {3, 1, 2}
    local ok, err = pcall(table.sort, t, function()
        local s = enter("t.lt:170")
        hold(attach(new_logged(log, "in comparator"), false, s))
        error("cmp", 0)
    end)
    test.assert_false(ok)
    test.assert_eq(err, "cmp")
    test.assert_deep_eq(log, {"in comparator (anchor)"})
    test.assert_eq(depth(), before)
end)

------------------------------------------------------------------------
test.suite("unwind: what it costs and holds")

test.case("pcall with up to three arguments and xpcall allocate nothing, on the success and the error path", function()
    local e = {}
    local function raise()
        error(e)
    end
    local function three(a, b, c)
        return a, b, c
    end
    local function handler(x)
        return x
    end
    local function run(n)
        for _ = 1, n do
            pcall(raise)
            pcall(three)
            pcall(three, 1)
            pcall(three, 1, 2)
            pcall(three, 1, 2, 3)
            pcall(raise, 1, 2, 3)
            xpcall(raise, handler)
            xpcall(three, handler)
        end
    end
    run(5000)
    collectgarbage("collect")
    collectgarbage("stop")
    local c0 = collectgarbage("count")
    run(1000)
    local used = collectgarbage("count") - c0
    collectgarbage("restart")
    test.assert_eq(used, 0, "KB allocated")
end)

test.case("the runtime keeps no argument, error value or handler once the call has returned", function()
    -- CLAUDE.md, rule 6. Each value is referred to only by a weak table
    -- once the call returns; two collections clear it.
    local weak = setmetatable({}, {__mode = "v"})
    local function noop()
    end
    local function raise(x)
        error(x, 0)
    end
    pcall(noop, {}, {}, {})
    pcall(noop, {}, {}, {}, {}, {})
    pcall(raise, {})
    xpcall(raise, function(m)
        return m
    end, {})
    do
        local a1, a2, a3, a4, e, h = {}, {}, {}, {}, {}, function(m)
            return m
        end
        weak[1], weak[2], weak[3], weak[4], weak[5], weak[6] = a1, a2, a3, a4, e, h
        pcall(noop, a1, a2, a3)
        pcall(noop, a1, a2, a3, a4)
        pcall(raise, e)
        xpcall(function()
            error(e, 0)
        end, h)
    end
    collectgarbage("collect")
    collectgarbage("collect")
    test.assert_eq(next(weak), nil, "every value collected")
end)

test.case("a debug hook that calls pcall with arguments between a call and its function does not take its arguments", function()
    -- Lua 5.1 carries the arguments of a Lua function through slots; a
    -- call hook can run between the slots' assignment and the carrier
    -- (lifetime/init.lua, `carried_back`). LuaJIT passes them itself.
    local got = {}
    local inside = false
    local function g(x)
        return x
    end
    debug.sethook(function()
        if not inside then
            inside = true
            pcall(g, "hook's")
            pcall(g, "hook's", 2, 3)
            inside = false
        end
    end, "c")
    local function f(a, b, c, d)
        got[#got + 1] = table.concat({tostring(a), tostring(b), tostring(c), tostring(d)}, " ")
        return a
    end
    local ok1, r1 = pcall(f, 1, 2)
    local ok2, r2 = pcall(f, 1, 2, 3, 4)
    debug.sethook()
    test.assert_true(ok1)
    test.assert_true(ok2)
    test.assert_eq(r1, 1)
    test.assert_eq(r2, 1)
    test.assert_deep_eq(got, {"1 2 nil nil", "1 2 3 4"})
end)

return test
