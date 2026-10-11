-- .vscode/launch.lua: what the configurations of .vscode/launch.json run
-- (editor/README.md, "Running and debugging"). From the repository root,
-- `lua .vscode/launch.lua FILE [ARGS]` is `lua bin/lifetime run FILE
-- [ARGS]`, with the debugger of the "Local Lua Debugger" extension
-- (tomblind.local-lua-debugger-vscode) attached when the extension
-- started the process. Nothing here is part of the command; bin/lifetime
-- never reads it.
--
-- The debugger cannot be handed bin/lifetime itself. Once started it
-- replaces `error`, `assert`, `debug.traceback` and `coroutine.wrap` with
-- functions that stop at every raise, caught or not, and raise the error
-- value again as a string. The transpiler raises tables that it catches
-- itself (lifetime/lexer.lua, lifetime/emit.lua), and the runtime asks
-- the host how `coroutine.wrap` re-raises a number (lifetime/init.lua,
-- `WRAP_PREFIXES_NUMBERS`), so under those replacements most programs
-- print nothing and exit with status 1. This script starts the debugger
-- first, puts the host's functions back, and only then loads the command,
-- so the program observes what it observes under `lifetime run`.
--
-- `coroutine.create` stays the debugger's: it creates through the host's
-- and registers the thread, which the debugger needs before it can stop
-- inside it. The runtime binds it when it loads, so the coroutines of
-- its `coroutine.wrap` are registered too. With "breakInCoroutines" on,
-- the debugger's `coroutine.create` also wraps the body in a protected
-- call that turns an error into a string, so that option is refused.
--
-- What is lost is the debugger's stop on an uncaught error: `lifetime
-- run` reports it, with its traceback, on standard error.

if os.getenv("LOCAL_LUA_DEBUGGER_VSCODE") == "1" then
    if os.getenv("LOCAL_LUA_DEBUGGER_BREAK_IN_COROUTINES") == "1" then
        io.stderr:write("launch.lua: set \"breakInCoroutines\" to false in .vscode/launch.json\n")
        os.exit(2)
    end
    local host_error, host_assert, host_traceback = error, assert, debug.traceback
    local host_resume, host_wrap = coroutine.resume, coroutine.wrap
    -- Stops here until the extension has sent the breakpoints.
    require("lldebugger").start()
    rawset(_G, "error", host_error)
    rawset(_G, "assert", host_assert)
    rawset(debug, "traceback", host_traceback)
    rawset(coroutine, "resume", host_resume)
    rawset(coroutine, "wrap", host_wrap)
end

-- `arg` as `lua bin/lifetime run FILE [ARGS]` sets it: bin/lifetime at 0,
-- which is where it looks for the checkout; `run` and this script's
-- arguments from 1; the interpreter and its options below 0.
local argv = {[0] = "bin/lifetime", "run"}
for i = 1, #arg do
    argv[i + 1] = arg[i]
end
local i = -1
while arg[i] ~= nil do
    argv[i] = arg[i]
    i = i - 1
end
arg = argv

-- The status is bin/lifetime's: it raises `nil` for 1, which the
-- interpreter reports as nothing before it closes the state.
return dofile("bin/lifetime")
