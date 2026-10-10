-- trial/treflove/run.lua: the Treflove trial of task 009. From the
-- repository root:
--
--   luajit trial/treflove/run.lua
--
-- Loads the slice of Treflove under trial/treflove/ through the
-- repository's own transpiler (harness.lua, the "lifetime" universe), runs
-- the scenarios of scenario.lt, and compares each scenario's log, whole
-- and in order, with the sequence written below (CLAUDE.md, rule 3:
-- every destruction is asserted by its order and by the statement that
-- causes it; a death by reachability is pinned with
-- collectgarbage("collect"), twice where a weak table must clear). Exit
-- status 0 when every log matches, 1 otherwise. `make test` runs it under
-- luajit when luajit is on PATH.
--
-- The log is written by instrumentation added here, not by the slice:
-- every class of the slice gets a release() that logs
-- `Class:release(reason)` and calls the class's own release(), or logs
-- `Class destroyed (reason)` when the class has none (Session,
-- LoginScreen, the test input), so the destructor bodies of the cascade
-- show up in the order the runtime calls them. A call made from inside a
-- logged method is indented by two spaces per level, which shows the
-- nested release() of Login:release and each remote procedure's stop()
-- reaching its connection. `Connection:unregister_request_handler` and
-- `FormScreen:remove_input` are logged the same way. `destroyerror` logs
-- the errors the runtime routes to it.
--
-- Test case 3 runs twice: with utils/class.lt, which registers every
-- instance in its constructor, and with variants/unregistered/, the same
-- class library without that line (README.md, "A collected session").
package.path = "./?.lua;./?/init.lua;" .. package.path

local harness = require("trial.treflove.harness")

local lines
local depth = 0

local function log(line)
    -- Addresses differ between runs; the log keeps their place.
    line = line:gsub("0x%x+", "0x?")
    lines[#lines + 1] = string.rep("  ", depth) .. line
end

-- Calls `f` one level deeper in the log, restoring the level when `f`
-- raises (a destructor body that fails, test case 3).
local function deeper(f, ...)
    depth = depth + 1
    local result = {pcall(f, ...)}
    depth = depth - 1
    if not result[1] then
        error(result[2], 0)
    end
    return unpack(result, 2)
end

local function label(self)
    local name = rawget(self, "name")
    return name and (" " .. name) or ""
end

local function instrument_release(class, name)
    local release = class.release
    class.release = function(self, reason)
        if release then
            log(name .. ":release(" .. (reason or "") .. ")" .. label(self))
            return deeper(release, self, reason)
        end
        log(name .. " destroyed (" .. tostring(reason) .. ")" .. label(self))
    end
end

local function instrument_method(class, name, method, describe)
    local f = class[method]
    class[method] = function(self, x)
        log(name .. ":" .. method .. "(" .. describe(x) .. ")")
        return deeper(f, self, x)
    end
end

local CLASSES = {
    {"networking.connection", "Connection"},
    {"game.session", "Session"},
    {"login.login", "Login"},
    {"login.login-rp", "LoginRp"},
    {"login.logout-rp", "LogoutRp"},
    {"game.game-data-rp", "GameDataRp"},
    {"data.upload-asset-rp", "UploadAssetRp"},
    {"data.download-asset-rp", "DownloadAssetRp"},
    {"data.download-missing-assets-rp", "DownloadMissingAssetsRp"},
    {"screens.user-menu-screen", "UserMenuScreen"},
    {"login.login-screen", "LoginScreen"},
    {"ui.form-screen", "FormScreen"}
}

-- The transpiled slice, instrumented, and its scenarios. `variant` as in
-- harness.universe.
local function instrumented(variant)
    local env = harness.universe("lifetime", log, variant)
    local scenario = env.require("scenario")
    for _, entry in ipairs(CLASSES) do
        instrument_release(env.require(entry[1]), entry[2])
    end
    instrument_release(scenario.TestInput, "TestInput")
    instrument_method(env.require("networking.connection"), "Connection", "unregister_request_handler", tostring)
    instrument_method(env.require("ui.form-screen"), "FormScreen", "remove_input", function(input)
        return input.name
    end)
    return env, scenario
end

local env, scenario = instrumented(nil)
local unregistered_env, unregistered_scenario = instrumented("unregistered")

-- docs/02-semantics.md, "Errors in destructors and `destroyerror`": read
-- raw from _G when an error is routed.
rawset(_G, "destroyerror", function(_, err)
    log("destroyerror: " .. tostring(err))
end)

-- The remote procedures' stop() on one connection, as Login's nested
-- release() and the cascade call them.
local function rp(reason, name, indent)
    indent = indent or ""
    return {indent .. name .. ":release(" .. reason .. ")", indent .. "  Connection:unregister_request_handler(" .. name .. ")"}
end

local function concat(...)
    local out = {}
    for i = 1, select("#", ...) do
        local part = select(i, ...)
        if type(part) == "string" then
            out[#out + 1] = part
        else
            for _, line in ipairs(part) do
                out[#out + 1] = line
            end
        end
    end
    return out
end

-- Below the session, in the order of docs/02-semantics.md, "Cascading
-- death": the session's dependents most recently attached first. Session:init
-- attached Login, GameDataRp, then AssetManager:register_session the
-- upload, download and download-missing procedures; Login:init attached
-- LoginRp then LogoutRp. Login's own release() runs first and calls both
-- procedures' release() by hand; then they die themselves, newest first.
local function session_procedures(reason)
    return concat(rp(reason, "DownloadMissingAssetsRp"), rp(reason, "DownloadAssetRp"), rp(reason, "UploadAssetRp"), rp(reason, "GameDataRp"), "Login:release(" .. reason .. ")", rp("", "LoginRp", "  "), rp("", "LogoutRp", "  "), rp(reason, "LogoutRp"), rp(reason, "LoginRp"))
end

local END = "> end: collectgarbage(\"collect\") twice"

local SCENARIOS = {
    {
        -- Test case 1 (trial/treflove/README.md, "The teardown").
        name = "teardown",
        expected = concat("> connect", "> server frame", "> client frame", "notify: Successfully logged in as adam", "> client: connection_manager:remove(connection)", "Connection:release(destroy)", "Session destroyed (anchor)",
            -- The period, attached last: its back entry (attached after the
            -- menu) is removed first, then the menu screen dies.
            "UserMenuScreen:release(anchor)", "  back stack depth 0", session_procedures("anchor"), "> server: connection_manager:remove(connection)", "Connection:release(destroy)", "Session destroyed (anchor)", session_procedures("anchor"), "client connection alive: false", "session alive: false, login alive: false", "app.session: nil, back stack depth: 0", "in channel released: true", "connection manager empty: true", "upload entry before collect: true, alive: false", "> collectgarbage(\"collect\") twice", "upload entries after collect: 0", END)
    },
    {
        name = "logout",
        expected = concat("> connect, server frame, client frame", "notify: Successfully logged in as adam", "logged in: true, back stack depth: 1", "> client: backstack_manager:back()", "back stack depth: 0", "> server frame", "> client frame", "UserMenuScreen:release(anchor)", "  back stack depth 0", "logged in: false, shown: LoginScreen", "> client: connection_manager:remove(connection)", "Connection:release(destroy)", "Session destroyed (anchor)", "LoginScreen destroyed (anchor)", session_procedures("anchor"), "> server: connection_manager:remove(connection)", "Connection:release(destroy)", "Session destroyed (anchor)", session_procedures("anchor"), END)
    },
    {
        -- Test case 2, first run.
        name = "input_first",
        expected = concat("inputs: {a, b}", "> lifetime.destroy(a)", "TestInput destroyed (destroy) a", "FormScreen:remove_input(a)", "inputs: {b}, a alive: false, b alive: true", "> cleanup: lifetime.destroy(form), lifetime.destroy(b)", "FormScreen:release(destroy)", "TestInput destroyed (destroy) b", END)
    },
    {
        -- Test case 2, second run.
        name = "form_first",
        expected = concat("hooks on a: 1, on b: 1", "> lifetime.destroy(form)", "FormScreen:release(destroy)", "inputs: {a, b}, form alive: false", "hooks on a: 0, on b: 0", "> cleanup: lifetime.destroy(a), lifetime.destroy(b)", "TestInput destroyed (destroy) a", "TestInput destroyed (destroy) b", END)
    },
    {
        -- Test case 2, third run.
        name = "one_cascade",
        expected = concat("> lifetime.destroy(period)", "FormScreen:release(anchor)", "TestInput destroyed (anchor) b", "TestInput destroyed (anchor) a", "inputs: {false, false}, form alive: false", END)
    },
    {
        -- Test case 3. Within one collection the collector finalizes newest
        -- first by creation (docs/02-semantics.md, "Reachability is the
        -- collector's"); class() registers every instance before its init,
        -- so the order is the reverse of the constructors' order and each
        -- procedure dies before its owner, with "unreachable". Login's
        -- nested release() then meets a tombstone, and the error goes to
        -- destroyerror (a finalizer has no statement to raise at).
        name = "collected",
        expected = concat("sessions: 1, per-session upload entries: 1", "> the server drops the session from its table and forgets the connection, without destroy", "> collectgarbage(\"collect\")", rp("unreachable", "DownloadMissingAssetsRp"), rp("unreachable", "DownloadAssetRp"), rp("unreachable", "UploadAssetRp"), rp("unreachable", "GameDataRp"), rp("unreachable", "LogoutRp"), rp("unreachable", "LoginRp"), "Login:release(unreachable)", "destroyerror: trial/treflove/login/login.lt:50: attempt to index a dead table (table: 0x?, died at collector, unreachable)", "Session destroyed (unreachable)", "Connection:release(unreachable)", "> collectgarbage(\"collect\")", "per-session entries left: 0, in channel released: true", END)
    },
    {
        -- Test case 3 again, with utils/class.lt without the registration
        -- line (variants/unregistered/). Every instance is then armed at
        -- its first `@` (docs/03-runtime.md, "The sentinel"): a procedure
        -- at its own `@ self`, an anchor at its first link, so the login
        -- after its procedures, the session after its login, and the
        -- connection, first seen at `Session(connection) @ connection`,
        -- last of all. The connection's finalizer runs first and its
        -- cascade takes the subtree in ownership order with "anchor"; the
        -- later finalizers find their objects dead.
        name = "collected",
        label = "collected, unregistered",
        unregistered = true,
        expected = concat("sessions: 1, per-session upload entries: 1", "> the server drops the session from its table and forgets the connection, without destroy", "> collectgarbage(\"collect\")", "Connection:release(unreachable)", "Session destroyed (anchor)", session_procedures("anchor"), "> collectgarbage(\"collect\")", "per-session entries left: 0, in channel released: true", END)
    },
    {
        name = "serializer",
        expected = concat("pairs sees the state record: true", "table.to_string equal to the unseen copy: true", "table.from_string gives a plain table: true", "table.copy copies the state record: true", "table.is_empty of an empty seen table: false", END)
    }
}

-- `run.lua [--print] [SCENARIO]`: one scenario only; print every log.
local only, print_logs
for _, a in ipairs(arg or {}) do
    if a == "--print" then
        print_logs = true
    else
        only = a
    end
end
local failed = 0
for _, s in ipairs(SCENARIOS) do
    local title = s.label or s.name
    if not only or only == s.name then
        lines = {}
        depth = 0
        local run_env, run_scenario = env, scenario
        if s.unregistered then
            run_env, run_scenario = unregistered_env, unregistered_scenario
        end
        local ok, err = pcall(run_scenario[s.name], harness, run_env)
        if not ok then
            log("error: " .. tostring(err))
        end
        log(END)
        collectgarbage("collect")
        collectgarbage("collect")
        local mismatch
        for i = 1, math.max(#lines, #s.expected) do
            if lines[i] ~= s.expected[i] then
                mismatch = i
                break
            end
        end
        if mismatch then
            failed = failed + 1
            io.write("[FAIL] ", title, ": first difference at line ", mismatch, "\n")
            io.write("  expected: ", tostring(s.expected[mismatch]), "\n")
            io.write("  actual:   ", tostring(lines[mismatch]), "\n")
            io.write("  actual log:\n")
            for i, line in ipairs(lines) do
                io.write(string.format("  %3d %s\n", i, line))
            end
        else
            io.write("[PASS] ", title, " (", #lines, " lines)\n")
            if print_logs then
                for _, line in ipairs(lines) do
                    io.write("  ", line, "\n")
                end
            end
        end
    end
end
io.write(failed == 0 and "trial/treflove: all scenarios match\n" or ("trial/treflove: " .. failed .. " scenario(s) differ\n"))
io.stdout:flush()
os.exit(failed == 0 and 0 or 1)
