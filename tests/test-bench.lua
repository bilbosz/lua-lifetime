-- tests/test-bench.lua: the benchmark harness, bench/lib/bench.lua
-- (task 010). Timings are fake: a clock is injected that advances by a
-- fixed cost per call of the benchmarked function, so every number below
-- is exact up to floating-point rounding.
local test = require("tests.lib.test")
local bench = require("bench.lib.bench")

local function assert_close(actual, expected, message)
    test.assert_true(math.abs(actual - expected) < 1e-6 * math.max(1, math.abs(expected)), string.format("%s: expected %s, got %s", message or "value", tostring(expected), tostring(actual)))
end

-- A fake clock and two functions whose calls advance it by `cost` and
-- `baseline_cost` seconds. `jump(at, seconds)` makes the call number `at`
-- of `fn` also advance the clock by `seconds` (a busy moment).
local function fake_timing(cost, baseline_cost)
    local now = 0
    local calls = 0
    local jumps = {}
    local timing = {}
    function timing.clock()
        return now
    end
    function timing.fn()
        calls = calls + 1
        now = now + cost + (jumps[calls] or 0)
    end
    function timing.baseline()
        now = now + baseline_cost
    end
    function timing.jump(at, seconds)
        jumps[at] = seconds
    end
    function timing.calls()
        return calls
    end
    return timing
end

test.suite("bench harness")

test.case("median of an odd and an even count, input untouched", function()
    local values = {5, 1, 4, 2, 3}
    test.assert_eq(bench.median(values), 3)
    test.assert_deep_eq(values, {5, 1, 4, 2, 3})
    test.assert_eq(bench.median({4, 1, 3, 2}), 2.5)
    test.assert_eq(bench.median({7}), 7)
    test.assert_error(function()
        bench.median({})
    end, "no values")
end)

test.case("ns per operation from an injected clock", function()
    local timing = fake_timing(2e-6, 1e-6)
    local ns, ratio = bench.measure({fn = timing.fn}, {clock = timing.clock, time = 0.01, runs = 5})
    assert_close(ns, 2000, "ns/op")
    test.assert_eq(ratio, nil, "no baseline, no ratio")
end)

test.case("ratio to the baseline", function()
    local timing = fake_timing(3e-6, 2e-6)
    local ns, ratio = bench.measure({fn = timing.fn, baseline = timing.baseline}, {clock = timing.clock, time = 0.01, runs = 5})
    assert_close(ns, 3000, "ns/op")
    assert_close(ratio, 1.5, "ratio")
end)

test.case("the warm-up runs before the timed runs and each run spends the budget", function()
    local timing = fake_timing(1e-6, 1e-6)
    local batch = bench.calibrate(timing.fn, 0.02, timing.clock)
    -- The first batch of at least 1/20 of the budget (1 ms, 1000 calls)
    -- in doubling sizes: 1024, after 1 + 2 + ... + 1024 = 2047 calls.
    test.assert_eq(batch, 1024)
    test.assert_eq(timing.calls(), 2047)
    bench.timed_run(timing.fn, batch, 0.02, timing.clock)
    -- 20 ms at 1 µs per call is 20 000 calls; whole batches of 1024: 20.
    test.assert_eq(timing.calls() - 2047, 20 * 1024)
end)

test.case("one busy run does not move the median", function()
    local timing = fake_timing(1e-6, 1e-6)
    -- Call 5000 is in the first timed run (the warm-up takes 1023 calls at
    -- time = 0.01: the batch reaches 512); that run reads 100 ms more.
    timing.jump(5000, 0.1)
    local ns, ratio = bench.measure({fn = timing.fn, baseline = timing.baseline}, {clock = timing.clock, time = 0.01, runs = 5})
    test.assert_true(timing.calls() > 5000, "the jump happened")
    assert_close(ns, 1000, "ns/op")
    assert_close(ratio, 1, "ratio")
end)

test.case("BENCH_TIME is the default budget", function()
    -- The environment cannot be set from Lua 5.1; check whatever it is.
    local value = os.getenv("BENCH_TIME")
    if value == nil or value == "" then
        test.assert_eq(bench.budget(), 0.5)
    else
        test.assert_eq(bench.budget(), tonumber(value))
    end
end)

test.suite("bench output")

test.case("one line per benchmark: name, ns/op, ratio", function()
    test.assert_eq(bench.format_line("build/plain.lt", 1234.56, 22.81949), "build/plain.lt\t1234.6\t22.819")
    test.assert_eq(bench.format_line("runtime/anchor", 50, nil), "runtime/anchor\t50.0\t-")
end)

test.case("lines parse back", function()
    local name, ns, ratio = bench.parse_line("build/plain.lt\t1234.6\t22.819")
    test.assert_eq(name, "build/plain.lt")
    test.assert_eq(ns, 1234.6)
    test.assert_eq(ratio, 22.819)
    name, ns, ratio = bench.parse_line("runtime/anchor\t50.0\t-")
    test.assert_eq(name, "runtime/anchor")
    test.assert_eq(ns, 50)
    test.assert_eq(ratio, nil)
    test.assert_eq(bench.parse_line("== bench under luajit"), nil)
    test.assert_eq(bench.parse_line("a\tb\tc"), nil)
end)

test.case("run writes one line per entry, in order, and reports errors", function()
    local timing = fake_timing(1e-6, 4e-6)
    local lines, errors = {}, {}
    local failed = bench.run({
        entries = {
            {name = "a", fn = timing.fn, baseline = timing.baseline},
            {name = "broken", fn = function()
                error("boom", 0)
            end},
            {name = "b", fn = timing.baseline}
        },
        clock = timing.clock,
        time = 0.01,
        runs = 3,
        write = function(line)
            lines[#lines + 1] = line
        end,
        report_error = function(name, message)
            errors[#errors + 1] = name .. ": " .. message
        end
    })
    test.assert_eq(failed, 1)
    test.assert_deep_eq(lines, {"a\t1000.0\t0.250\n", "b\t4000.0\t-\n"})
    test.assert_deep_eq(errors, {"broken: boom"})
end)

test.case("add validates its arguments and registers in order", function()
    test.assert_error(function()
        bench.add("a\tb", function() end)
    end, "without tabs")
    test.assert_error(function()
        bench.add("x", nil)
    end, "fn must be a function")
    test.assert_error(function()
        bench.add("x", function() end, {baseline = 1})
    end, "baseline must be a function")
    local before = #bench.entries()
    local fn, baseline = function() end, function() end
    bench.add("test/registered", fn, {baseline = baseline})
    local entries = bench.entries()
    test.assert_eq(#entries, before + 1)
    test.assert_deep_eq(entries[#entries], {name = "test/registered", fn = fn, baseline = baseline})
    entries[#entries] = nil
end)

test.suite("bench/run.lua")

local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return ""
    end
    local data = f:read("*a")
    f:close()
    return data
end

local function write_file(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

-- Run bench/run.lua under the interpreter running this suite, with a
-- tiny budget; returns stdout, stderr and the exit status (through files,
-- as tests/conformance.lua does, because lua5.1 and luajit return
-- different things from os.execute).
local function run_bench(args)
    local interpreter = arg and arg[-1] or "lua5.1"
    local out, err, status = os.tmpname(), os.tmpname(), os.tmpname()
    os.execute(string.format("BENCH_TIME=0.001 %s bench/run.lua %s >%s 2>%s; echo $? >%s", shell_quote(interpreter), args, shell_quote(out), shell_quote(err), shell_quote(status)))
    local result = {stdout = read_file(out), stderr = read_file(err), status = tonumber(read_file(status):match("%d+"))}
    os.remove(out)
    os.remove(err)
    os.remove(status)
    return result
end

-- A fake lifetime/ under build/test-bench/fake and a benchmark file whose
-- benchmark name says which lifetime.cli it loaded.
local FIXTURE = "build/test-bench"
os.execute("mkdir -p " .. FIXTURE .. "/fake/lifetime " .. FIXTURE .. "/empty")
write_file(FIXTURE .. "/fake/lifetime/cli.lua", "return {WHO = \"fake\"}\n")
write_file(FIXTURE .. "/bench-probe.lua", table.concat({
    "local cli = require(\"lifetime.cli\")",
    "require(\"bench.lib.bench\").add(\"probe/\" .. (cli.WHO or \"branch\"), function() end)",
    ""
}, "\n"))

test.case("lifetime.* comes from the current directory by default", function()
    local r = run_bench(FIXTURE .. "/bench-probe.lua")
    test.assert_eq(r.stderr, "")
    test.assert_eq(r.status, 0)
    test.assert_eq(bench.parse_line(r.stdout:match("^([^\n]*)\n$") or ""), "probe/branch")
end)

test.case("--lifetime DIR takes lifetime.* from DIR", function()
    local r = run_bench("--lifetime " .. FIXTURE .. "/fake " .. FIXTURE .. "/bench-probe.lua")
    test.assert_eq(r.stderr, "")
    test.assert_eq(r.status, 0)
    test.assert_eq(bench.parse_line(r.stdout:match("^([^\n]*)\n$") or ""), "probe/fake")
end)

test.case("a module missing under DIR is an error, not the branch's module", function()
    local r = run_bench("--lifetime " .. FIXTURE .. "/empty " .. FIXTURE .. "/bench-probe.lua")
    test.assert_eq(r.stdout, "")
    test.assert_eq(r.status, 1)
    test.assert_true(r.stderr:find("module 'lifetime.cli' not found under " .. FIXTURE .. "/empty/", 1, true), "stderr: " .. r.stderr)
end)

test.suite("bench compare")

test.case("ratio branch/base per benchmark, marked beyond the threshold", function()
    local branch = "a\t110.0\t1.000\nb\t111.0\t-\nc\t50.0\t0.500\nnew\t10.0\t-\n"
    local base = "c\t100.0\t1.000\nb\t100.0\t-\na\t100.0\t1.000\n"
    test.assert_deep_eq(bench.compare(branch, base), {
        "a\t110.0\t100.0\t1.100\t", -- exactly 10% slower is within the threshold
        "b\t111.0\t100.0\t1.110\tSLOWER",
        "c\t50.0\t100.0\t0.500\t",
        "new\t10.0\t-\t-\t" -- the base could not run it
    })
end)

test.case("an explicit threshold", function()
    test.assert_deep_eq(bench.compare("a\t105.0\t-\n", "a\t100.0\t-\n", 1.02), {"a\t105.0\t100.0\t1.050\tSLOWER"})
end)
