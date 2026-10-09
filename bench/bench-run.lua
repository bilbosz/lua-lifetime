-- bench/bench-run.lua: the startup of `lifetime run` (task 007;
-- docs/04-transpiler.md, "The command"), against the interpreter running
-- the generated file.
--
--   run/plain.lt  what `lifetime run examples/plain.lt` does in its
--                 process: `require("lifetime.cli")` with nothing loaded
--                 yet (the transpiler's modules read and compiled from
--                 their files, as bin/lifetime does), then `cli.main` on
--                 `run examples/plain.lt`, which reads the file, builds
--                 it, loads the result, requires the runtime and calls
--                 the chunk through the runtime's `xpcall`. The baseline
--                 is what `lua5.1 FILE` or `luajit FILE` does with the
--                 generated file: read it, load it, call it. The process
--                 start of the interpreter is the same on both sides and
--                 not measured. `print` is silenced on both sides, so
--                 that standard output stays benchmark lines only.
--
-- The difference is a fixed cost per run: nothing of it is per call or per
-- block, since the program runs as the same generated code on both sides
-- (task 007, "Performance"). Every operation loads fresh modules, and the
-- runtime replaces `pcall`, `xpcall`, `coroutine.resume` and
-- `coroutine.wrap` when it loads; they are put back after each operation
-- so that no operation wraps the previous one's. A base whose `cli.main`
-- cannot run the file (before task 007) gives a benchmark that raises,
-- which the harness reports while the other benchmarks still run.
local bench = require("bench.lib.bench")

local SOURCE = "examples/plain.lt"
local GENERATED = "build/bench-run/plain.lua"
local ARGV = {[-1] = "lua", [0] = "bin/lifetime", "run", SOURCE}
local MODULES = {"lifetime", "lifetime.cli", "lifetime.lexer", "lifetime.parser", "lifetime.emit"}

local original_print, original_arg = print, arg
local original_pcall, original_xpcall = pcall, xpcall
local original_resume, original_wrap = coroutine.resume, coroutine.wrap

local function silent()
end

-- One `lifetime run SOURCE` with no module loaded; returns the status.
local function run_once()
    local loaded = package.loaded
    for i = 1, #MODULES do
        loaded[MODULES[i]] = nil
    end
    rawset(_G, "print", silent)
    local status = require("lifetime.cli").main(ARGV)
    rawset(_G, "print", original_print)
    rawset(_G, "arg", original_arg)
    rawset(_G, "pcall", original_pcall)
    rawset(_G, "xpcall", original_xpcall)
    rawset(coroutine, "resume", original_resume)
    rawset(coroutine, "wrap", original_wrap)
    return status
end

-- The generated file, written once from the branch's (or the base's)
-- build of SOURCE.
local generated
do
    local f = assert(io.open(SOURCE, "rb"))
    local source = f:read("*a")
    f:close()
    generated = assert(require("lifetime.cli").build(source, SOURCE))
    os.execute("mkdir -p build/bench-run")
    f = assert(io.open(GENERATED, "wb"))
    f:write(generated)
    f:close()
end

local function run_generated()
    local f = assert(io.open(GENERATED, "rb"))
    local text = f:read("*a")
    f:close()
    rawset(_G, "print", silent)
    assert(loadstring(text, "@" .. GENERATED))()
    rawset(_G, "print", original_print)
end

local status = run_once()
bench.add("run/plain.lt", status == 0 and run_once or function()
    error("run/plain.lt: lifetime run exited with status " .. tostring(status), 0)
end, {baseline = run_generated})
