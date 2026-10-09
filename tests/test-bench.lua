-- tests/test-bench.lua: the benchmark harness, bench/lib/bench.lua
-- (task 010), and the alternating comparison of `make bench BASE=` with
-- its exit status (task 011). Timings are fake: a clock is injected that
-- advances by a fixed cost per call of the benchmarked function, so every
-- number below is exact up to floating-point rounding.
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

-- Task 013: one process per benchmark file. bench-first.lua sets a global
-- that bench-second.lua looks for; bench-env.lua names the interpreter
-- and the BENCH_TIME it saw; bench-probe2.lua is a second probe of
-- lifetime.cli; bench-raises.lua raises at load.
write_file(FIXTURE .. "/bench-first.lua", table.concat({
    "BENCH_TEST_GLOBAL = \"set by bench-first.lua\"",
    "require(\"bench.lib.bench\").add(\"probe/first\", function() end)",
    ""
}, "\n"))
write_file(FIXTURE .. "/bench-second.lua", table.concat({
    "local seen = rawget(_G, \"BENCH_TEST_GLOBAL\") and \"shared\" or \"fresh\"",
    "require(\"bench.lib.bench\").add(\"probe/second-\" .. seen, function() end)",
    ""
}, "\n"))
write_file(FIXTURE .. "/bench-env.lua", table.concat({
    "local interpreter = rawget(_G, \"jit\") and \"jit\" or \"puc\"",
    "require(\"bench.lib.bench\").add(\"probe/env-\" .. interpreter .. \"-\" .. tostring(os.getenv(\"BENCH_TIME\")), function() end)",
    ""
}, "\n"))
write_file(FIXTURE .. "/bench-probe2.lua", table.concat({
    "local cli = require(\"lifetime.cli\")",
    "require(\"bench.lib.bench\").add(\"probe2/\" .. (cli.WHO or \"branch\"), function() end)",
    ""
}, "\n"))
write_file(FIXTURE .. "/bench-raises.lua", "error(\"raised at load\", 0)\n")

-- The benchmark names of a run's standard output, in order; nil when a
-- line is not a benchmark line.
local function names_of(stdout)
    local names = {}
    for line in stdout:gmatch("([^\n]*)\n") do
        names[#names + 1] = bench.parse_line(line) or ("not a benchmark line: " .. line)
    end
    return names
end

local THIS_INTERPRETER = rawget(_G, "jit") and "jit" or "puc"

test.case("each file in its own process, in file order, same interpreter, BENCH_TIME forwarded", function()
    local files = " " .. FIXTURE .. "/bench-second.lua " .. FIXTURE .. "/bench-first.lua " .. FIXTURE .. "/bench-second.lua " .. FIXTURE .. "/bench-env.lua"
    local r = run_bench(files)
    test.assert_eq(r.stderr, "")
    test.assert_eq(r.status, 0)
    -- The global bench-first.lua set is absent in the next file's process.
    test.assert_deep_eq(names_of(r.stdout), {"probe/second-fresh", "probe/first", "probe/second-fresh", "probe/env-" .. THIS_INTERPRETER .. "-0.001"})
end)

test.case("--in-process runs every file in one process, as before task 013", function()
    local r = run_bench("--in-process " .. FIXTURE .. "/bench-second.lua " .. FIXTURE .. "/bench-first.lua " .. FIXTURE .. "/bench-second.lua")
    test.assert_eq(r.stderr, "")
    test.assert_eq(r.status, 0)
    test.assert_deep_eq(names_of(r.stdout), {"probe/second-fresh", "probe/first", "probe/second-shared"})
end)

test.case("--lifetime DIR reaches every file's process", function()
    local r = run_bench("--lifetime " .. FIXTURE .. "/fake " .. FIXTURE .. "/bench-probe.lua " .. FIXTURE .. "/bench-first.lua " .. FIXTURE .. "/bench-probe2.lua")
    test.assert_eq(r.stderr, "")
    test.assert_eq(r.status, 0)
    test.assert_deep_eq(names_of(r.stdout), {"probe/fake", "probe/first", "probe2/fake"})
    r = run_bench(FIXTURE .. "/bench-probe.lua " .. FIXTURE .. "/bench-probe2.lua")
    test.assert_deep_eq(names_of(r.stdout), {"probe/branch", "probe2/branch"}, "without --lifetime")
end)

test.case("a file that raises at load: named on stderr, the other files still run, exit 1", function()
    local r = run_bench(FIXTURE .. "/bench-first.lua " .. FIXTURE .. "/bench-raises.lua " .. FIXTURE .. "/bench-second.lua")
    test.assert_eq(r.status, 1)
    test.assert_deep_eq(names_of(r.stdout), {"probe/first", "probe/second-fresh"})
    -- The child's own message, then the parent's, both naming the file.
    test.assert_eq(r.stderr, "bench: " .. FIXTURE .. "/bench-raises.lua: raised at load\n" .. "bench: " .. FIXTURE .. "/bench-raises.lua: its process exited with status 1\n")
    -- In one process the same file fails the same way, without the
    -- parent's line.
    r = run_bench("--in-process " .. FIXTURE .. "/bench-first.lua " .. FIXTURE .. "/bench-raises.lua " .. FIXTURE .. "/bench-second.lua")
    test.assert_eq(r.status, 1)
    test.assert_deep_eq(names_of(r.stdout), {"probe/first", "probe/second-shared"})
    test.assert_eq(r.stderr, "bench: " .. FIXTURE .. "/bench-raises.lua: raised at load\n")
end)

test.case("a file whose process dies without a word is still reported", function()
    -- os.exit from inside the benchmark file: no bench message, status 3.
    write_file(FIXTURE .. "/bench-exits.lua", "os.exit(3)\n")
    local r = run_bench(FIXTURE .. "/bench-exits.lua " .. FIXTURE .. "/bench-first.lua")
    test.assert_eq(r.status, 1)
    test.assert_deep_eq(names_of(r.stdout), {"probe/first"})
    test.assert_eq(r.stderr, "bench: " .. FIXTURE .. "/bench-exits.lua: its process exited with status 3\n")
end)

test.suite("bench compare")

-- bench/README.md, "The threshold": SLOWER only when both pairings of
-- alternating runs exceed bench.THRESHOLD; the ratio of the medians is
-- reported beside the two pairings (task 011).
test.case("two pairings both over the threshold: SLOWER, ratio of the medians", function()
    test.assert_deep_eq(bench.compare({
        {"a\t112.0\t1.000\n", "a\t100.0\t1.000\n"},
        {"a\t113.0\t1.000\n", "a\t100.0\t1.000\n"}
    }), {"a\t112.5\t100.0\t1.120\t1.130\t1.125\tSLOWER"})
end)

test.case("one pairing over the threshold: not marked, both shown", function()
    test.assert_deep_eq(bench.compare({
        {"a\t112.0\t-\n", "a\t100.0\t-\n"},
        {"a\t104.0\t-\n", "a\t100.0\t-\n"}
    }), {"a\t108.0\t100.0\t1.120\t1.040\t1.080\t"})
    -- The other order; a ratio of the medians over the threshold does not
    -- mark on its own either.
    test.assert_deep_eq(bench.compare({
        {"a\t100.0\t-\n", "a\t100.0\t-\n"},
        {"a\t130.0\t-\n", "a\t100.0\t-\n"}
    }), {"a\t115.0\t100.0\t1.000\t1.300\t1.150\t"})
end)

test.case("neither pairing over the threshold; exactly 10% slower is within it", function()
    test.assert_deep_eq(bench.compare({
        {"a\t110.0\t1.000\nc\t50.0\t0.500\n", "c\t100.0\t1.000\na\t100.0\t1.000\n"},
        {"c\t60.0\t0.500\na\t110.0\t1.000\n", "a\t100.0\t1.000\nc\t100.0\t1.000\n"}
    }), {
        "a\t110.0\t100.0\t1.100\t1.100\t1.100\t",
        "c\t55.0\t100.0\t0.500\t0.600\t0.550\t"
    })
end)

test.case("a benchmark the base cannot run: '-' for that pairing, never marked", function()
    test.assert_deep_eq(bench.compare({
        {"a\t200.0\t-\nnew\t10.0\t-\n", "a\t100.0\t-\n"},
        {"a\t200.0\t-\nnew\t12.0\t-\n", "new\t5.0\t-\n"}
    }), {
        -- a: the base ran it in pairing 1 only; 2.0 there, still no mark.
        "a\t200.0\t100.0\t2.000\t-\t-\t",
        -- new: the base ran it in pairing 2 only.
        "new\t11.0\t5.0\t-\t2.400\t-\t"
    })
    test.assert_deep_eq(bench.compare({
        {"new\t10.0\t-\n", ""},
        {"new\t12.0\t-\n", ""}
    }), {"new\t11.0\t-\t-\t-\t-\t"})
end)

test.case("benchmarks in the branch's order; one only in pairing 2 comes last", function()
    test.assert_deep_eq(bench.compare({
        {"b\t100.0\t-\na\t100.0\t-\n", "a\t100.0\t-\nb\t100.0\t-\nz\t1.0\t-\n"},
        {"z\t1.0\t-\na\t100.0\t-\nb\t100.0\t-\n", "a\t100.0\t-\nb\t100.0\t-\nz\t1.0\t-\n"}
    }), {
        "b\t100.0\t100.0\t1.000\t1.000\t1.000\t",
        "a\t100.0\t100.0\t1.000\t1.000\t1.000\t",
        "z\t1.0\t1.0\t-\t1.000\t-\t"
    })
end)

test.case("an explicit threshold, and one pairing alone", function()
    test.assert_deep_eq(bench.compare({{"a\t105.0\t-\n", "a\t100.0\t-\n"}}, 1.02), {"a\t105.0\t100.0\t1.050\t1.050\tSLOWER"})
    test.assert_error(function()
        bench.compare({})
    end, "no pairings")
end)

test.suite("bench/compare.lua")

-- Run a shell command; returns stdout, stderr and the exit status, through
-- files as run_bench does.
local function run_shell(command)
    local out, err, status = os.tmpname(), os.tmpname(), os.tmpname()
    os.execute(string.format("%s >%s 2>%s; echo $? >%s", command, shell_quote(out), shell_quote(err), shell_quote(status)))
    local result = {stdout = read_file(out), stderr = read_file(err), status = tonumber(read_file(status):match("%d+"))}
    os.remove(out)
    os.remove(err)
    os.remove(status)
    return result
end

local INTERPRETER = arg and arg[-1] or "lua5.1"

test.case("pairs of files, one line per benchmark; usage and read errors fail", function()
    write_file(FIXTURE .. "/b1.txt", "a\t112.0\t-\n")
    write_file(FIXTURE .. "/a1.txt", "a\t100.0\t-\n")
    write_file(FIXTURE .. "/b2.txt", "a\t113.0\t-\n")
    write_file(FIXTURE .. "/a2.txt", "a\t100.0\t-\n")
    local compare = shell_quote(INTERPRETER) .. " bench/compare.lua "
    local r = run_shell(compare .. table.concat({FIXTURE .. "/b1.txt", FIXTURE .. "/a1.txt", FIXTURE .. "/b2.txt", FIXTURE .. "/a2.txt"}, " "))
    test.assert_eq(r.stderr, "")
    test.assert_eq(r.status, 0)
    test.assert_eq(r.stdout, "a\t112.5\t100.0\t1.120\t1.130\t1.125\tSLOWER\n")
    r = run_shell(compare .. FIXTURE .. "/b1.txt " .. FIXTURE .. "/a1.txt " .. FIXTURE .. "/b2.txt")
    test.assert_eq(r.status, 2, "an odd number of files")
    test.assert_true(r.stderr:find("usage", 1, true), "stderr: " .. r.stderr)
    r = run_shell(compare .. FIXTURE .. "/b1.txt " .. FIXTURE .. "/missing.txt")
    test.assert_eq(r.status, 1, "a file that cannot be read")
    test.assert_true(r.stderr:find("missing.txt", 1, true), "stderr: " .. r.stderr)
end)

-- The cases below run `make`; without it on PATH they are not registered
-- (task 011, review round 1, F1), so the suite still runs where only an
-- interpreter is installed.
local make_case
if run_shell("command -v make").status == 0 then
    test.suite("make bench")
    make_case = test.case
else
    print("tests/test-bench.lua: make not on PATH; the make bench cases are skipped")
    make_case = function() end
end

-- `make bench` itself, run as a subprocess under the interpreter running
-- this suite, with a tiny budget, BENCH_FILES set to fixtures (so a run
-- takes well under a second) and BENCH_OUT under FIXTURE (so the
-- build/bench-*.txt of a real run are left alone). BASE_DIR points at an
-- existing tree, so nothing is checked out.
write_file(FIXTURE .. "/bench-plainprobe.lua", "require(\"bench.lib.bench\").add(\"probe/plain\", function() end)\n")
write_file(FIXTURE .. "/bench-broken.lua", "error(\"broken fixture\", 0)\n")

local OUT = FIXTURE .. "/out"

local function make_bench(variables)
    os.execute("rm -rf " .. shell_quote(OUT))
    -- MAKEFLAGS and MAKELEVEL emptied: under `make test` the outer make's
    -- flags and command-line variables must not reach this one.
    return run_shell(string.format("MAKEFLAGS= MAKELEVEL= BENCH_TIME=0.001 make -s --no-print-directory bench INTERPRETERS=%s BENCH_OUT=%s %s", shell_quote(INTERPRETER), OUT, variables))
end

local function out_file(name)
    return read_file(OUT .. "/" .. name)
end

local function out_exists(name)
    local f = io.open(OUT .. "/" .. name, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

make_case("a base run with no benchmark line fails make bench BASE=, naming the interpreter", function()
    local r = make_bench("BASE=empty BASE_DIR=" .. FIXTURE .. "/empty BENCH_FILES=" .. FIXTURE .. "/bench-probe.lua")
    test.assert_eq(r.status, 2, "make's status for a failed recipe")
    test.assert_true(r.stderr:find("make: bench under " .. INTERPRETER .. ": the base run of pairing 1 (lifetime/ of empty in " .. FIXTURE .. "/empty) printed no benchmark line", 1, true), "stderr: " .. r.stderr)
    -- The base run's own error stays on stderr.
    test.assert_true(r.stderr:find("module 'lifetime.cli' not found under " .. FIXTURE .. "/empty/", 1, true), "stderr: " .. r.stderr)
    test.assert_eq(out_file("bench-" .. INTERPRETER .. "-1.txt"):match("^probe/branch\t"), "probe/branch\t")
    test.assert_eq(out_file("bench-base-" .. INTERPRETER .. "-1.txt"), "")
    test.assert_false(out_exists("bench-" .. INTERPRETER .. "-2.txt"), "no second pairing after a base with no line")
    test.assert_false(out_exists("bench-compare-" .. INTERPRETER .. ".txt"), "no comparison after a base with no line")
end)

make_case("branch, base, branch, base; a base that fails some files passes with '-'", function()
    local r = make_bench("BASE=empty BASE_DIR=" .. FIXTURE .. "/empty BENCH_FILES='" .. FIXTURE .. "/bench-probe.lua " .. FIXTURE .. "/bench-plainprobe.lua'")
    test.assert_eq(r.status, 0, "stderr: " .. r.stderr)
    -- Four runs, alternating, each announced on stdout.
    local order = {}
    for n, side in r.stdout:gmatch("== bench under [^\n]-, pairing (%d) of 2, (%a+)") do
        order[#order + 1] = n .. " " .. side
    end
    test.assert_deep_eq(order, {"1 branch", "1 on", "2 branch", "2 on"})
    -- The base's failure stays on stderr, once per base run.
    local _, failures = r.stderr:gsub("module 'lifetime%.cli' not found under " .. FIXTURE:gsub("%p", "%%%0") .. "/empty/", "")
    test.assert_eq(failures, 2, "stderr: " .. r.stderr)
    for n = 1, 2 do
        local branch = out_file("bench-" .. INTERPRETER .. "-" .. n .. ".txt")
        test.assert_true(branch:match("^probe/branch\t[^\n]+\nprobe/plain\t[^\n]+\n$") ~= nil, "branch run " .. n .. ": " .. branch)
        local base = out_file("bench-base-" .. INTERPRETER .. "-" .. n .. ".txt")
        test.assert_true(base:match("^probe/plain\t[^\n]+\n$") ~= nil, "base run " .. n .. ": " .. base)
    end
    local compare = out_file("bench-compare-" .. INTERPRETER .. ".txt")
    test.assert_true(compare:match("^probe/branch\t[%d.]+\t%-\t%-\t%-\t%-\t\nprobe/plain\t[%d.]+\t[%d.]+\t[%d.]+\t[%d.]+\t[%d.]+\t%a*\n$") ~= nil, "compare: " .. compare)
    test.assert_true(r.stdout:find(compare, 1, true) ~= nil, "the comparison is printed too")
    test.assert_false(out_exists("bench-" .. INTERPRETER .. ".txt"), "BASE= writes the numbered files only")
end)

make_case("a branch run that fails fails make bench, with BASE= or without", function()
    local files = "BENCH_FILES='" .. FIXTURE .. "/bench-broken.lua " .. FIXTURE .. "/bench-plainprobe.lua'"
    local r = make_bench(files)
    test.assert_eq(r.status, 2, "without BASE: " .. r.stderr)
    test.assert_true(r.stderr:find("bench: " .. FIXTURE .. "/bench-broken.lua: broken fixture", 1, true), "stderr: " .. r.stderr)
    test.assert_eq(out_file("bench-" .. INTERPRETER .. ".txt"):match("^probe/plain\t"), "probe/plain\t", "the other files still ran")
    r = make_bench("BASE=fake BASE_DIR=" .. FIXTURE .. "/fake " .. files)
    test.assert_eq(r.status, 2, "with BASE: " .. r.stderr)
    test.assert_true(out_exists("bench-compare-" .. INTERPRETER .. ".txt"), "the comparison still ran")
end)

make_case("make bench without BASE: one run per interpreter", function()
    local r = make_bench("BENCH_FILES=" .. FIXTURE .. "/bench-plainprobe.lua")
    test.assert_eq(r.status, 0, "stderr: " .. r.stderr)
    test.assert_eq(r.stderr, "")
    local _, runs = r.stdout:gsub("== bench under ", "")
    test.assert_eq(runs, 1)
    test.assert_true(out_file("bench-" .. INTERPRETER .. ".txt"):match("^probe/plain\t[^\n]+\n$") ~= nil)
    test.assert_false(out_exists("bench-" .. INTERPRETER .. "-1.txt"))
    test.assert_false(out_exists("bench-base-" .. INTERPRETER .. "-1.txt"))
end)
