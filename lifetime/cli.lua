-- lifetime/cli.lua: the pipeline and the command.
--
-- `build(source, chunkname)` chains lexer, parser and emitter and returns
-- the generated Lua source, or nil and a message on a syntax error.
-- `main(argv)` is the command of docs/04-transpiler.md, "The command":
-- `lifetime build FILE -o OUT` and `lifetime run FILE [ARGS]`; it returns
-- the exit status, which bin/lifetime turns into the process's (task 007).

local lexer = require("lifetime.lexer")
local parser = require("lifetime.parser")
local emit = require("lifetime.emit")

local cli = {}

local find, match, sub = string.find, string.match, string.sub

-- A syntax error is recognised by a marker, not by the chunkname prefix
-- of its message (task 001, review round 2): a transpiler bug raised
-- while building a file whose name is the bug's source position would
-- read like a syntax error otherwise. The lexer and the parser use their
-- chunkname only to prefix their messages, so they are given the
-- chunkname behind this marker, which no other error can start with (a
-- NUL cannot begin a position), and `build` strips it. The emitter
-- writes its chunkname into the generated positions and so gets the real
-- one; its only syntax error, the `goto` into a scoped block
-- (docs/04-transpiler.md, "Blocks"), is recognised by its whole shape.
local MARKER = "\0lifetime syntax error\0"
-- The label is a name as the lexer reads it: bytes 128 to 255 included
-- (LuaJIT's lexical extension, lifetime/lexer.lua).
local GOTO_ERROR = "^:%d+: <goto [%a_\128-\255][%w_\128-\255]*> jumps into the scope of a lifetime$"

local function build(source, chunkname)
    local marked = MARKER .. chunkname
    -- Deferred lexing: a malformed token is reported when the parser
    -- reaches it, so errors come in the order Lua reports them.
    local ast = parser.parse(lexer.tokenize(source, marked, true), marked)
    return emit.emit(ast, chunkname)
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
    if type(result) == "string" then
        if sub(result, 1, #MARKER) == MARKER then
            return nil, sub(result, #MARKER + 1)
        end
        local n = #chunkname
        if sub(result, 1, n) == chunkname and find(result, GOTO_ERROR, n + 1) then
            return nil, result
        end
    end
    error(result, 0)
end

------------------------------------------------------------------------
-- The command
------------------------------------------------------------------------

local USAGE = "usage: lifetime build FILE -o OUT\n       lifetime run FILE [ARGS]\n"

-- Exit statuses: 0 success; 1 a syntax error, an unreadable file or an
-- uncaught error (as the standalone interpreter); 2 a usage error.
local function usage()
    io.stderr:write(USAGE)
    return 2
end

-- `lifetime: <message>` on standard error, as the standalone interpreter
-- reports with its own name (lua.c, `l_message`).
local function report(message)
    io.stdout:flush()
    io.stderr:write("lifetime: ", message, "\n")
    io.stderr:flush()
    return 1
end

-- The contents of `path`, or nil and Lua's own message for a file it
-- cannot open (`luaL_loadfile`: "cannot open <file>: <reason>").
local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then
        return nil, "cannot open " .. err
    end
    local data = f:read("*a")
    f:close()
    if not data then
        return nil, "cannot read " .. path
    end
    return data
end

-- `lifetime build FILE -o OUT`; `-o -` writes to standard output.
-- docs/04-transpiler.md, "The command": "Exit status 1 and a message on
-- standard error for a syntax error, in the shape `FILE:LINE:
-- <message>`." The options may come before or after FILE.
local function build_command(argv)
    local file, out
    local i, n = 2, #argv
    while i <= n do
        local a = argv[i]
        if a == "-o" then
            if out ~= nil or i == n then
                return usage()
            end
            out = argv[i + 1]
            i = i + 2
        elseif file == nil then
            file = a
            i = i + 1
        else
            return usage()
        end
    end
    if file == nil or out == nil then
        return usage()
    end
    local source, err = read_file(file)
    if not source then
        return report(err)
    end
    local generated, message = cli.build(source, file)
    if not generated then
        io.stderr:write(message, "\n")
        return 1
    end
    if out == "-" then
        io.stdout:write(generated)
        io.stdout:flush()
        return 0
    end
    local f, open_error = io.open(out, "wb")
    if not f then
        return report("cannot open " .. open_error)
    end
    local ok, write_error = f:write(generated)
    f:close()
    if not ok then
        return report("cannot write " .. out .. ": " .. tostring(write_error))
    end
    return 0
end

-- The message of an uncaught error object, as the standalone interpreter
-- renders it (lua.c, `traceback` and `report`): a string or a number as
-- it is; anything else through its `__tostring`, else named by its type,
-- as LuaJIT's standalone interpreter does.
local function error_message(err)
    local t = type(err)
    if t == "string" or t == "number" then
        return err
    end
    local mt = getmetatable(err)
    if type(mt) == "table" and mt.__tostring then
        local ok, s = pcall(tostring, err)
        if ok and type(s) == "string" then
            return s
        end
    end
    return "(error object is a " .. t .. " value)"
end

-- The message handler of `run` for the chunk `main`: the message and a
-- traceback from the raise point, as the standalone interpreter's
-- (`debug.traceback(message, 2)`), without the frames below the chunk,
-- which are this module's and the runtime's. `debug.traceback` prints
-- one line per stack level and keeps the outermost levels whole when it
-- elides, so dropping one line per level below the chunk's is exact.
local function handler_for(main)
    return function(err)
        local text = debug.traceback(error_message(err), 2)
        local level, chunk_level = 2, nil
        while true do
            local info = debug.getinfo(level, "f")
            if not info then
                break
            end
            if info.func == main then
                chunk_level = level
            end
            level = level + 1
        end
        if not chunk_level then
            return text
        end
        for _ = chunk_level + 1, level - 1 do
            text = match(text, "^(.*)\n[^\n]*$") or text
        end
        return text
    end
end

-- Returns its argument. Calling the chunk through `identity(chunk)(...)`
-- leaves the call without a name, so the traceback says "in main chunk"
-- for it, as the standalone interpreter's does, rather than naming a
-- local of this module.
local function identity(f)
    return f
end

-- `lifetime run FILE [ARGS]` (docs/04-transpiler.md, "The command"):
-- "transpile and run in the current interpreter with the chunk name
-- `FILE`, `arg` set as the standalone interpreter sets it, and the exit
-- flag of 03, "Program end", set after the chunk returns. An uncaught
-- error is reported as `lifetime: <message>` with a traceback on standard
-- error and exit status 1, as the standalone interpreter reports it."
local function run_command(argv)
    local file = argv[2]
    if file == nil then
        return usage()
    end
    local source, err = read_file(file)
    if not source then
        return report(err)
    end
    -- A `#!` first line is the lexer's (task 005), which keeps the line
    -- count as `luaL_loadfile` does.
    local generated, message = cli.build(source, file)
    if not generated then
        return report(message)
    end
    -- The chunk name `luaL_loadfile` gives the file (`@FILE`): positions
    -- read `FILE:LINE:`, and a long name keeps its tail.
    local chunk, load_error = loadstring(generated, "@" .. file)
    if not chunk then
        return report(load_error)
    end
    -- Required here, whether the chunk requires it or not, so that the
    -- protected call below is the runtime's, which unwinds every scope
    -- left open (docs/04-transpiler.md, "The error path": "`lifetime run`
    -- calls it through the runtime's `pcall`").
    local lifetime = require("lifetime")
    -- `arg` as lua.c's `getargs` sets it: the script at 0, its arguments
    -- from 1, and everything before the script (the interpreter, its
    -- options, bin/lifetime and `run`) at negative indices. The arguments
    -- are also the chunk's `...`.
    local script_arg = {}
    local first = 0
    while argv[first - 1] ~= nil do
        first = first - 1
    end
    local n = #argv
    for i = first, n do
        script_arg[i - 2] = argv[i]
    end
    rawset(_G, "arg", script_arg)
    n = n - 2
    -- The runtime's `xpcall` (the global, replaced when `lifetime` was
    -- required; docs/03-runtime.md, "The scope stack and the error
    -- path"): it unwinds as its `pcall` does, and its message handler
    -- runs at the raise point, before any record is unwound, so the
    -- traceback is the raise point's while the report below comes after
    -- the main scope's cascade. Not a tail call, so the chunk's frame
    -- stays in the traceback.
    local ok, failure = xpcall(function()
        identity(chunk)(unpack(script_arg, 1, n))
    end, handler_for(chunk))
    local status = 0
    if not ok then
        status = report(failure)
    end
    -- docs/03-runtime.md, "Program end": "`lifetime run` sets an exit
    -- flag after the main chunk has returned and its scope epilogue has
    -- run; from then on the sentinel finalizers that the closing state
    -- runs report `"exit"`." The runtime function is task 004's; until it
    -- exists there is no sentinel and nothing to tell. After an uncaught
    -- error the flag is set too, after the report: the state closes all
    -- the same (task 007, "Spec issues found").
    local set_exiting = lifetime.set_exiting
    if set_exiting then
        set_exiting(true)
    end
    return status
end

-- The command. `argv` is the `arg` table of bin/lifetime: the subcommand
-- at 1. Returns the exit status; bin/lifetime ends the process with it
-- and lets the interpreter close the state, which runs the finalizers of
-- docs/02-semantics.md, "Program end", step 2.
function cli.main(argv)
    local command = argv[1]
    if command == "build" then
        return build_command(argv)
    elseif command == "run" then
        return run_command(argv)
    end
    return usage()
end

return cli
