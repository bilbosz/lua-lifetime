-- bench/bench-treflove.lua: the Treflove trial of task 009, the first
-- numbers from a real program (tasks/009-treflove-trial.md,
-- "Performance"). Both sides run the same slice of Treflove in one
-- process (trial/treflove/harness.lua): the benchmark is the slice
-- transpiled from trial/treflove/*.lt with the anchors of idioms A, B and
-- C; the baseline is Treflove's hand-written code (trial/treflove/original/)
-- with its release() chain, loaded as it is. Everything else (the
-- verbatim files, the mocks, the stubs) is the same file on both sides.
--
--   treflove/cycle           one connect-login-disconnect cycle between a
--                            client and a server over Treflove's fake
--                            channels: two connections, two sessions with
--                            a login, two remote procedures and a game data
--                            procedure each, three asset procedures each,
--                            the client's logged-in period with its menu
--                            screen and back entry; the login round trip;
--                            then ConnectionManager:remove on both sides,
--                            which is one destroy(connection) each in the
--                            benchmark and the release() chain in the
--                            baseline
--   treflove/dispatch-frame  one frame of the client's update event
--                            manager over 10 connected, logged-in
--                            connections with nothing to read: the event
--                            dispatch, which no block of the slice anchors
--                            to lifetime.scope, so the transpiled code is
--                            Treflove's own; ratio 1.0 within noise
local bench = require("bench.lib.bench")
local harness = require("trial.treflove.harness")

local function apps(kind)
    local env = harness.universe(kind)
    return env, harness.new_app(env, "client"), harness.new_app(env, "server")
end

local lt_env, lt_client, lt_server = apps("lifetime")
local hw_env, hw_client, hw_server = apps("original")

bench.add("treflove/cycle", function()
    harness.cycle(lt_env, lt_client, lt_server)
end, {
    baseline = function()
        harness.cycle(hw_env, hw_client, hw_server)
    end
})

local CONNECTIONS = 10

-- The server is kept in the environment, which the benchmark holds: a
-- server app nobody refers to would take its connections to the
-- collector in the middle of the timed runs.
local function connected(kind)
    local env, client, server = apps(kind)
    env.trial_server = server
    for _ = 1, CONNECTIONS do
        harness.connect(env, client, server)
    end
    harness.frame(env, server)
    harness.frame(env, client)
    return env, client
end

local lt_frame_env, lt_frame_client = connected("lifetime")
local hw_frame_env, hw_frame_client = connected("original")

bench.add("treflove/dispatch-frame", function()
    harness.frame(lt_frame_env, lt_frame_client)
end, {
    baseline = function()
        harness.frame(hw_frame_env, hw_frame_client)
    end
})
