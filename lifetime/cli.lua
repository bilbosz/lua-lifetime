-- lifetime/cli.lua: the pipeline and the command.
--
-- `build(source, chunkname)` chains lexer, parser and emitter and returns
-- the generated Lua source, or nil and a message on a syntax error.
-- `main(argv)` is the command of docs/04-transpiler.md, "The command":
-- `lifetime build FILE -o OUT` and `lifetime run FILE [ARGS]`.
--
-- `main` is task 007.

local lexer = require("lifetime.lexer")
local parser = require("lifetime.parser")
local emit = require("lifetime.emit")

local cli = {}

local find = string.find

local function build(source, chunkname)
    -- Deferred lexing: a malformed token is reported when the parser
    -- reaches it, so errors come in the order Lua reports them.
    local tokens = lexer.tokenize(source, chunkname, true)
    return emit.emit(parser.parse(tokens, chunkname), chunkname)
end

-- docs/04-transpiler.md, "Pipeline": `build(source, chunkname)`, lexer ->
-- parser -> emit. Returns the generated source, or nil and the message
-- `chunkname:line: <message>` on a syntax error. Any other error is a bug
-- in the transpiler and propagates.
function cli.build(source, chunkname)
    local ok, result = pcall(build, source, chunkname)
    if ok then
        return result
    end
    if type(result) == "string" and find(result, chunkname .. ":", 1, true) == 1 then
        return nil, result
    end
    error(result, 0)
end

function cli.main(argv) -- luacheck: no unused args
    io.stderr:write("lifetime: the command is not implemented yet (task 007)\n")
    return 2
end

return cli
