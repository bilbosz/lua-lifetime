-- lifetime/cli.lua: the pipeline and the command.
--
-- `build(source, chunkname)` chains lexer, parser and emitter and returns
-- the generated Lua source, or nil and a message on a syntax error.
-- `main(argv)` is the command of docs/04-transpiler.md, "The command":
-- `lifetime build FILE -o OUT` and `lifetime run FILE [ARGS]`.
--
-- Bootstrap skeleton. `build` is a placeholder that returns the source
-- unchanged so that the conformance runner has something to run on
-- examples/plain.lt; task 001 replaces it with the real round trip through
-- lexer, parser and emitter. `main` is task 007.

local cli = {}

-- Placeholder (bootstrap): pass the source through. Task 001 replaces this
-- body with lexer -> parser -> emit.
function cli.build(source, chunkname) -- luacheck: no unused args
    return source
end

function cli.main(argv) -- luacheck: no unused args
    io.stderr:write("lifetime: the command is not implemented yet (task 007)\n")
    return 2
end

return cli
