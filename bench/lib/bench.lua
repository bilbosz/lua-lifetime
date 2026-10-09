-- bench/lib/bench.lua: the zero-dependency benchmark harness of task 010.
--
-- CLAUDE.md, rule 5: "the cost is measured, not guessed: a task that
-- touches a hot path adds or updates a benchmark under `bench/`, and
-- `make bench` ... compares the branch with `master` on the same machine."
-- docs/03-runtime.md, "Performance": `make bench` measures each line of
-- the free, cheap and forced lists against plain Lua doing the same work
-- by hand; the `baseline` of a benchmark is that plain Lua.
--
--   local bench = require("bench.lib.bench")
--   bench.add("name", function() ... end, {baseline = function() ... end})
--
-- One call of `fn` is one operation. Each benchmark is warmed up, then
-- timed for RUNS runs of a fixed budget each (BENCH_TIME seconds, default
-- 0.5); the reported time is the median of the runs in ns per operation.
-- A baseline is timed the same way, its runs interleaved with the
-- benchmark's so that a busy moment hits both, and the ratio is
-- median(fn) / median(baseline). bench/README.md says how to read it.
--
-- The clock is os.clock, the process's CPU time: Lua 5.1 has no
-- sub-second wall clock, and for a single-threaded benchmark that does
-- no I/O the two advance together, CPU time without the time spent
-- descheduled on a busy machine.
--
-- Output, one line per benchmark (bench/run.lua):
--
--   name<TAB>ns/op<TAB>ratio          (ratio is "-" without a baseline)
--
-- and, comparing a branch with a base over two pairings of alternating
-- runs, branch base branch base (bench/compare.lua, `make bench BASE=`):
--
--   name<TAB>branch ns/op<TAB>base ns/op<TAB>pairing 1<TAB>pairing 2<TAB>branch/base<TAB>mark
local bench = {}

bench.RUNS = 5
bench.DEFAULT_TIME = 0.5
-- bench/README.md, "The threshold": a benchmark is a finding when it is
-- more than 10% slower than base in both of two pairings of alternating
-- runs. bench.compare applies the rule: SLOWER only when every pairing's
-- branch/base exceeds THRESHOLD.
bench.THRESHOLD = 1.10
bench.SLOWER = "SLOWER"

-- The warm-up doubles the batch size until one batch takes at least this
-- fraction of the budget; a timed run then reads the clock once per
-- batch, so the clock's own cost and resolution stay out of the result.
local BATCH_FRACTION = 1 / 20

local floor, format = math.floor, string.format

-- The registered benchmarks, in registration order.
local registry = {}

-- Register a benchmark. `options.baseline`, when given, is the plain-Lua
-- function doing the same work by hand; the ratio is reported against it.
function bench.add(name, fn, options)
    assert(type(name) == "string" and name ~= "" and not name:find("[\t\n]"), "bench.add: the name must be a non-empty string without tabs or newlines")
    assert(type(fn) == "function", "bench.add: fn must be a function")
    local baseline = options and options.baseline
    assert(baseline == nil or type(baseline) == "function", "bench.add: baseline must be a function")
    registry[#registry + 1] = {name = name, fn = fn, baseline = baseline}
end

-- The registered benchmarks, in registration order.
function bench.entries()
    return registry
end

-- The budget of one timed run in seconds: BENCH_TIME, or the default.
function bench.budget()
    local value = os.getenv("BENCH_TIME")
    if value == nil or value == "" then
        return bench.DEFAULT_TIME
    end
    local seconds = tonumber(value)
    assert(seconds and seconds > 0, "BENCH_TIME must be a positive number of seconds, got " .. value)
    return seconds
end

-- The median of a non-empty array of numbers; the array is not modified.
function bench.median(values)
    local n = #values
    assert(n > 0, "bench.median: no values")
    local sorted = {}
    for i = 1, n do
        sorted[i] = values[i]
    end
    table.sort(sorted)
    local middle = floor((n + 1) / 2)
    if n % 2 == 1 then
        return sorted[middle]
    end
    return (sorted[middle] + sorted[middle + 1]) / 2
end

-- Seconds taken by `batch` calls of `fn`.
local function time_batch(fn, batch, clock)
    local start = clock()
    for _ = 1, batch do
        fn()
    end
    return clock() - start
end

-- The warm-up: run `fn` in doubling batches until one batch takes at
-- least BATCH_FRACTION of the budget. Returns that batch size.
function bench.calibrate(fn, budget, clock)
    local target = budget * BATCH_FRACTION
    local batch = 1
    while time_batch(fn, batch, clock) < target do
        batch = batch * 2
    end
    return batch
end

-- One timed run: whole batches of `fn` until `budget` seconds have
-- passed on `clock`. Returns the time per operation in ns.
function bench.timed_run(fn, batch, budget, clock)
    collectgarbage("collect")
    local ops, start = 0, clock()
    local elapsed
    repeat
        for _ = 1, batch do
            fn()
        end
        ops = ops + batch
        elapsed = clock() - start
    until elapsed >= budget
    return elapsed / ops * 1e9
end

-- Measure one entry `{name = ..., fn = ..., baseline = ...}`.
-- `options.clock` (default os.clock), `options.time` (default
-- bench.budget()) and `options.runs` (default bench.RUNS) let the tests
-- inject a clock. Returns the median ns/op of `fn` and the ratio to the
-- median of the baseline, nil without a baseline.
function bench.measure(entry, options)
    options = options or {}
    local clock = options.clock or os.clock
    local budget = options.time or bench.budget()
    local runs = options.runs or bench.RUNS
    local fn, baseline = entry.fn, entry.baseline
    local fn_batch = bench.calibrate(fn, budget, clock)
    local baseline_batch = baseline and bench.calibrate(baseline, budget, clock)
    local fn_times, baseline_times = {}, {}
    for run = 1, runs do
        fn_times[run] = bench.timed_run(fn, fn_batch, budget, clock)
        if baseline then
            baseline_times[run] = bench.timed_run(baseline, baseline_batch, budget, clock)
        end
    end
    local ns = bench.median(fn_times)
    if not baseline then
        return ns, nil
    end
    return ns, ns / bench.median(baseline_times)
end

-- The output line of one benchmark: `name<TAB>ns/op<TAB>ratio`.
function bench.format_line(name, ns, ratio)
    return format("%s\t%.1f\t%s", name, ns, ratio and format("%.3f", ratio) or "-")
end

-- Parse one output line of bench.run. Returns name, ns/op and ratio (nil
-- for "-"), or nil when the line is not a benchmark line.
function bench.parse_line(line)
    local name, ns, ratio = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)$")
    ns = ns and tonumber(ns)
    if not ns then
        return nil
    end
    return name, ns, tonumber(ratio)
end

local function report_to_stderr(name, message)
    io.stderr:write(format("bench: %s: %s\n", name, message))
end

local function write_to_stdout(line)
    io.stdout:write(line)
    io.stdout:flush()
end

-- Run every entry (`options.entries`, default the registry) and write one
-- line per benchmark with `options.write` (default: stdout, flushed). An
-- entry that raises produces no line and is reported with
-- `options.report_error(name, message)` (default: to stderr). The other
-- options are bench.measure's. Returns the number of entries that raised.
function bench.run(options)
    options = options or {}
    local write = options.write or write_to_stdout
    local report_error = options.report_error or report_to_stderr
    local failed = 0
    for _, entry in ipairs(options.entries or registry) do
        local ok, ns, ratio = pcall(bench.measure, entry, options)
        if ok then
            write(bench.format_line(entry.name, ns, ratio) .. "\n")
        else
            failed = failed + 1
            report_error(entry.name, tostring(ns))
        end
    end
    return failed
end

-- The benchmark lines of an output text: the names in order, and a map
-- from name to ns/op.
local function index_lines(text)
    local names, ns_of = {}, {}
    for line in text:gmatch("[^\n]+") do
        local name, ns = bench.parse_line(line)
        if name then
            if ns_of[name] == nil then
                names[#names + 1] = name
            end
            ns_of[name] = ns
        end
    end
    return names, ns_of
end

local function format_ns(ns)
    return ns and format("%.1f", ns) or "-"
end

local function format_ratio(ratio)
    return ratio and format("%.3f", ratio) or "-"
end

-- Compare a branch with a base over `pairings`, an array of
-- `{branch_text, base_text}` in bench.run's format, one per pair of
-- alternating runs (`make bench BASE=` makes two: branch, base, branch,
-- base; task 011, "the noise is between processes, not within one, so
-- the lever is alternation"). Returns an array of lines, one per
-- benchmark the branch ran, in the order the branch first printed them:
--
--   name<TAB>branch ns/op<TAB>base ns/op<TAB>pairing 1<TAB>...<TAB>pairing N<TAB>branch/base<TAB>mark
--
-- `branch ns/op` and `base ns/op` are the medians of each side's runs
-- that produced the benchmark; `pairing k` is branch/base within pairing
-- k; `branch/base` is the ratio of the two medians. A side missing from
-- a pairing (the base could not run the benchmark) makes that pairing
-- "-", and `branch/base` "-" unless every pairing has both sides. `mark`
-- is bench.SLOWER when every pairing's ratio exceeds `threshold`
-- (default bench.THRESHOLD; bench/README.md, "The threshold"), empty
-- otherwise; a pairing with "-" is never over it.
function bench.compare(pairings, threshold)
    threshold = threshold or bench.THRESHOLD
    assert(#pairings > 0, "bench.compare: no pairings")
    local names, seen = {}, {}
    local branch_of, base_of = {}, {}
    for k = 1, #pairings do
        local branch_names, branch_ns = index_lines(pairings[k][1])
        local _, base_ns = index_lines(pairings[k][2])
        for i = 1, #branch_names do
            local name = branch_names[i]
            if not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
        branch_of[k], base_of[k] = branch_ns, base_ns
    end
    local lines = {}
    for i = 1, #names do
        local name = names[i]
        local mine, theirs, ratios = {}, {}, {}
        local complete, slower = true, true
        for k = 1, #pairings do
            local b, a = branch_of[k][name], base_of[k][name]
            mine[#mine + 1] = b
            theirs[#theirs + 1] = a
            local ratio = b and a and b / a
            ratios[k] = format_ratio(ratio)
            if not ratio then
                complete, slower = false, false
            elseif ratio <= threshold then
                slower = false
            end
        end
        local branch_median = #mine > 0 and bench.median(mine) or nil
        local base_median = #theirs > 0 and bench.median(theirs) or nil
        lines[i] = table.concat({
            name,
            format_ns(branch_median),
            format_ns(base_median),
            table.concat(ratios, "\t"),
            format_ratio(complete and branch_median / base_median or nil),
            slower and bench.SLOWER or ""
        }, "\t")
    end
    return lines
end

return bench
