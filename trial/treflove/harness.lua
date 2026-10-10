-- trial/treflove/harness.lua: loads the Treflove slice and drives a client
-- and a server over Treflove's fake channels (tests/lib/mocks.lua). Used by
-- trial/treflove/run.lua (the scenario) and bench/bench-treflove.lua (the
-- measurement). Not Treflove code. Run from the repository root.
--
-- A *universe* is one copy of the slice in an environment of its own, so
-- that the transpiled slice and Treflove's hand-written one can live in one
-- process (the benchmark needs both):
--
--   "lifetime"  every module is transpiled with the repository's
--               transpiler (lifetime.cli.build): X.lt if it exists, else
--               X.lua (a plain Lua file transpiles to itself), else
--               stubs/X.lua;
--   "original"  Treflove's hand-written code loaded as it is:
--               original/X.lua if it exists, else X.lua, else stubs/X.lua.
--
-- Each chunk runs with the universe's environment (setfenv): Treflove's
-- globals (`class`, `app`, `love`, `abstract`, …) are the universe's,
-- everything else is read from _G. `table.*` is shared: utils/table.lua is
-- the same file in both.
local harness = {}

harness.ROOT = "trial/treflove/"

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

local CANDIDATES = {
    lifetime = {"", ".lt", "", ".lua", "stubs/", ".lua"},
    original = {"original/", ".lua", "", ".lua", "stubs/", ".lua"}
}

-- A fresh universe of kind "lifetime" or "original". `log(line)` is what
-- the stubs and the instrumentation write to (the global `trial_log`).
function harness.universe(kind, log)
    local candidates = assert(CANDIDATES[kind], "universe: kind must be \"lifetime\" or \"original\"")
    local build
    if kind == "lifetime" then
        -- Required before any chunk of the slice runs, as `lifetime run`
        -- does (docs/02-semantics.md, "Scopes: `lifetime.scope`").
        require("lifetime")
        build = require("lifetime.cli").build
    end
    local env = setmetatable({}, {
        __index = _G
    })
    env.trial_log = log or function()
    end
    local loaded = {}
    local function universe_require(name)
        local value = loaded[name]
        if value ~= nil then
            return value
        end
        local base = (name:gsub("%.", "/"))
        local path, source
        for i = 1, #candidates, 2 do
            path = harness.ROOT .. candidates[i] .. base .. candidates[i + 1]
            source = read_file(path)
            if source then
                break
            end
        end
        if not source then
            -- `lifetime` and anything else outside the slice.
            return require(name)
        end
        if build then
            source = assert(build(source, path))
        end
        local chunk = assert(loadstring(source, "@" .. path))
        setfenv(chunk, env)
        value = chunk(name)
        if value == nil then
            value = true
        end
        loaded[name] = value
        return value
    end
    env.require = universe_require
    -- app/globals.lua without utils/dump.lua.
    universe_require("utils.table")
    universe_require("utils.utils")
    universe_require("utils.class")
    return env
end

-- Bytes as lowercase hex, standing in for base64.
local function hex(s)
    return (s:gsub(".", function(c)
        return string.format("%02x", c:byte())
    end))
end

-- The parts of `love` the slice touches beyond Treflove's mocks: hashing,
-- encoding and the seeded generator of utils/utils.lua (login), and the
-- file system calls of AssetManager:init on the server. Deterministic.
local function install_love_stubs(env)
    local mocks = env.require("tests.lib.mocks")
    mocks.ensure_love_data()
    local love = env.love
    love.data.encode = function(_, _, s)
        return hex(s)
    end
    love.data.hash = function(_, s)
        local h = 5381
        for i = 1, #s do
            h = (h * 33 + s:byte(i)) % 4294967296
        end
        return string.format("%08x", h)
    end
    love.math = {
        newRandomGenerator = function()
            local state = 1
            return {
                setSeed = function(_, seed)
                    state = seed % 2147483647
                end,
                random = function(_, lo, hi)
                    state = (state * 16807) % 2147483647
                    return lo + state % (hi - lo + 1)
                end
            }
        end
    }
    love.filesystem = {
        getInfo = function(path)
            if path == "server" then
                return {
                    type = "directory"
                }
            end
            return nil
        end,
        createDirectory = function()
        end,
        getDirectoryItems = function()
            return {}
        end,
        remove = function()
        end
    }
end

-- The `auth` the server stores for adam/krause: what LoginRp computes on
-- both sides (login/login.lua, login/login-rp.lua) with the stubs above.
local function server_auth(env)
    local Utils = env.require("utils.utils")
    env.app = {
        is_client = true,
        is_server = false
    }
    local client = Utils.hash("adam" .. string.char(0) .. Utils.generate_salt(32) .. string.char(0) .. "krause")
    env.app = {
        is_client = false,
        is_server = true
    }
    return Utils.hash("adam" .. string.char(0) .. Utils.generate_salt(32) .. string.char(0) .. client)
end

-- A client or a server app: Treflove's app mock (tests/lib/mocks.lua) with
-- the real update event manager, the managers the slice uses, and the
-- connection callbacks of app/client.lua or app/server.lua started.
function harness.new_app(env, side)
    if not env.love or not env.love.math then
        install_love_stubs(env)
    end
    local mocks = env.require("tests.lib.mocks")
    local is_server = side == "server"
    local auth = is_server and server_auth(env)
    local app = mocks.make_app({
        is_client = not is_server,
        is_server = is_server
    })
    app.update_event_manager = env.require("events.update-event").Manager()
    app.text_event_manager = {
        set_text_input = function()
        end
    }
    app.screen_manager = {
        show = function(_, screen)
            app.shown = screen
        end
    }
    app.notification_manager = {
        notify = function(_, text)
            env.trial_log("notify: " .. text)
        end
    }
    if is_server then
        app.data = {
            players = {
                adam = {
                    auth = auth
                }
            }
        }
    end
    env.app = app
    if not is_server then
        app.backstack_manager = env.require("utils.backstack-manager")()
    end
    app.connection_manager = env.require("networking.connection-manager")("localhost", "8080")
    app.asset_manager = env.require("data.asset-manager")()
    env.require(is_server and "app.server" or "app.client").load(app)
    return app
end

-- One frame of `app`: what love.update does with the update event manager
-- (app/app.lua), the connections' on_update included.
function harness.frame(env, app)
    env.app = app
    app.update_event_manager:invoke_event(env.require("events.update-event").Listener.on_update, 0.016)
end

-- Connect: the server and the client each add their end of a pair of fake
-- channels, back to back, as the connector would. The client's session
-- sends the login request (game/session.lua). Returns the client's and the
-- server's Connection.
function harness.connect(env, client_app, server_app)
    local mocks = env.require("tests.lib.mocks")
    local client_to_server = mocks.make_channel()
    local server_to_client = mocks.make_channel()
    env.app = server_app
    server_app.connection_manager:add_connection(client_to_server, mocks.make_thread(), server_to_client, mocks.make_thread())
    env.app = client_app
    client_app.connection_manager:add_connection(server_to_client, mocks.make_thread(), client_to_server, mocks.make_thread())
    return client_app.connection_manager._by_in_channel[server_to_client], server_app.connection_manager._by_in_channel[client_to_server]
end

-- Disconnect one end: ConnectionManager:remove, as the connector does when
-- a thread reports the socket closed.
function harness.disconnect(env, app, connection)
    env.app = app
    app.connection_manager:remove(connection)
end

-- One connect-login-disconnect cycle: connect, a server frame (the login
-- request is answered), a client frame (the response logs the user in),
-- then the client and the server each remove their connection.
function harness.cycle(env, client_app, server_app)
    local client_connection, server_connection = harness.connect(env, client_app, server_app)
    harness.frame(env, server_app)
    harness.frame(env, client_app)
    harness.disconnect(env, client_app, client_connection)
    harness.disconnect(env, server_app, server_connection)
end

return harness
