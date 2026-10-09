-- bench/bench-plain.lua: the "free" rule of docs/03-runtime.md,
-- "Performance": "Code that does not use the extension pays nothing: a
-- plain Lua chunk transpiles to itself". The benchmark runs the
-- transpiled output of a plain Lua chunk; the baseline runs the same
-- source loaded directly. The ratio must be 1.0 within noise.
--
--   plain/transpiled   bench/plain/workload.lua, built by cli.build,
--                      against the same file loaded with loadstring
local bench = require("bench.lib.bench")
local cli = require("lifetime.cli")

local PATH = "bench/plain/workload.lua"

local f = assert(io.open(PATH, "rb"))
local source = f:read("*a")
f:close()

local direct = assert(loadstring(source, "=" .. PATH))
local built = assert(loadstring(assert(cli.build(source, PATH)), "=" .. PATH))
-- Both must compute the same thing, or the comparison means nothing.
local expected, actual = direct(), built()
assert(actual == expected, string.format("%s: the transpiled chunk returned %s, the source %s", PATH, tostring(actual), tostring(expected)))

bench.add("plain/transpiled", built, {baseline = direct})
