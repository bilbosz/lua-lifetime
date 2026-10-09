-- bench/bench-build.lua: the transpiler, `cli.build` (docs/04-transpiler.md,
-- "Pipeline"), against Lua's own compiler on the same source. The
-- baseline is `loadstring`, the plain-Lua work of turning the same text
-- into a function; the ratio is how many compilations one transpilation
-- costs.
--
--   build/plain.lt          examples/plain.lt, a small program
--   build/generated-5000    a generated 5 000-line plain Lua file
--   build/lifetime-largest  the largest file under lifetime/ (today
--                           lifetime/parser.lua): the benchmark the
--                           `jit.off(true, true)` comments in
--                           lifetime/parser.lua and lifetime/emit.lua cite
--
-- Input files are read relative to the current directory, so under `make
-- bench BASE=<ref>` the base's transpiler gets the same text as the
-- branch's (bench/run.lua).
local bench = require("bench.lib.bench")
local cli = require("lifetime.cli")

local function read_file(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return data
end

-- The largest *.lua file under lifetime/, by size.
local function largest_lifetime_file()
    local best, best_size = nil, -1
    local p = io.popen("find lifetime -name '*.lua' -type f 2>/dev/null | sort")
    for path in p:lines() do
        local f = assert(io.open(path, "rb"))
        local size = f:seek("end")
        f:close()
        if size > best_size then
            best, best_size = path, size
        end
    end
    p:close()
    return assert(best, "no *.lua file under lifetime/")
end

-- A plain Lua chunk of exactly `lines` lines (a multiple of 10): groups of
-- ten lines that use every statement form and most expression forms,
-- each group in its own `do ... end` so the main function stays under
-- Lua 5.1's limit of 200 locals.
local function generate_plain_lua(lines)
    assert(lines % 10 == 0, "generate_plain_lua: lines must be a multiple of 10")
    local out = {}
    for k = 1, lines / 10 do
        out[#out + 1] = table.concat({
            string.format("do -- group %d", k),
            string.format("    local v, w = {%d, \"s%d\", %d.5, true, nil}, 0x%X", k, k, k, k),
            "    local function f(a, b, ...)",
            "        if a > b then return a - b elseif a == b then return select(\"#\", ...) else return -(b - a) % 7 end",
            "    end",
            "    for i = 1, #v do v[i] = tostring(v[i]) .. \"x\" end",
            string.format("    local t = {name = [[n%d]], list = {1, 2, 3; 4}, [\"key %d\"] = f(%d, 3), nested = {deep = {not w, #v}}}", k, k, k),
            "    while t.list[1] < 0 and t.nested.deep[2] ~= nil or w >= 2 ^ 3 do t.list[1] = t.list[1] + 1; break end",
            "    repeat w = w - 1 until w <= 0 or t.name:len() > 100",
            "end"
        }, "\n")
    end
    return table.concat(out, "\n") .. "\n"
end

local function add_build(name, source, chunkname)
    -- One build up front: a syntax error or a transpiler bug fails here,
    -- not inside the timed loop.
    assert(cli.build(source, chunkname))
    assert(loadstring(source, "=" .. chunkname))
    bench.add(name, function()
        cli.build(source, chunkname)
    end, {
        baseline = function()
            loadstring(source, "=" .. chunkname)
        end
    })
end

add_build("build/plain.lt", read_file("examples/plain.lt"), "examples/plain.lt")
add_build("build/generated-5000", generate_plain_lua(5000), "generated-5000.lua")
local largest = largest_lifetime_file()
add_build("build/lifetime-largest", read_file(largest), largest)
