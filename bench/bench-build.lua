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
--   parse/lifetime-largest  the same file, lexer and parser only (task 005)
--   parse/extension-5000    lexer and parser on a generated 5 000-line file
--                           that uses `@`, the list form, `!@` and
--                           `lifetime.scope` on most lines; the baseline
--                           is `loadstring` of the same file with the
--                           extension left out (task 005). A base that
--                           predates the extension cannot run it.
--   build/extension-5000    `cli.build` end to end on the same file (task
--                           007, from task 006's review, F1): its first
--                           `lifetime.scope` is on line 3, so the emission
--                           without the analysis stops at once and the
--                           chunk is analysed and emitted again; same
--                           baseline as parse/extension-5000
--   build/scope-at-end-5000 `cli.build` on build/generated-5000's file
--                           with `local last = {} @ lifetime.scope` added
--                           as its last line: the worst case of the
--                           emitter's restart, a whole emission thrown
--                           away, then the analysis and the emission
--                           again; the baseline is `loadstring` of the
--                           same file with the anchor left out, so the
--                           ratio reads against build/generated-5000's
--   build/teal-5000         `cli.build` with the Teal front end (task
--                           018, lifetime/teal.lua) on a generated
--                           5 000-line `.tlt` file: the groups of
--                           build/extension-5000 with types on most
--                           lines, a record, an enum, `as` and `is`;
--                           the baseline is `loadstring` of the same
--                           program as plain Lua, types and extension
--                           left out. A base without the front end
--                           cannot run it.
--   build/teal-fields-5000  `cli.build` with the Teal front end on 5 000
--                           lines of table constructors with typed fields
--                           (`{n: integer = 1, …}`), the constructor's
--                           speculative type read that commits (task 020);
--                           the baseline is `loadstring` of the same
--                           constructors untyped
--   build/teal-method-items-5000
--                           the same on 5 000 lines of constructors whose
--                           items start with `Name ':'` and are method
--                           calls (`{r:get(), …}`), the speculative read
--                           that backtracks (task 020); the source is
--                           plain Lua, the baseline its `loadstring`. A
--                           base before task 020 cannot run it.
--
-- Input files are read relative to the current directory, so under `make
-- bench BASE=<ref>` the base's transpiler gets the same text as the
-- branch's (bench/run.lua).
local bench = require("bench.lib.bench")
local cli = require("lifetime.cli")
local lexer = require("lifetime.lexer")
local parser = require("lifetime.parser")

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

-- A chunk of exactly `lines` lines (a multiple of 10) in groups of ten
-- lines, most of which use the extension: with `extended` false, the same
-- chunk with every `@ …` and `!@ …` left out, which is plain Lua.
local function generate_extended(lines, extended)
    assert(lines % 10 == 0, "generate_extended: lines must be a multiple of 10")
    local function ext(text)
        return extended and text or ""
    end
    local out = {}
    for k = 1, lines / 10 do
        out[#out + 1] = table.concat({
            string.format("do -- group %d", k),
            string.format("    local owner = {id = %d, list = {}}", k),
            "    local a, b = {1, 2}" .. ext(" @ lifetime.scope") .. ", {name = \"b\"}" .. ext(" @ (owner, lifetime.scope)"),
            "    local h = function(reason) owner.closed = reason end" .. ext(" !@ owner"),
            extended and string.format("    function() print(%d) end !@ lifetime.scope", k) or string.format("    local _ = function() print(%d) end", k),
            "    owner.child = setmetatable({}, owner)" .. ext(" @ lifetime.pin(owner, a)"),
            "    for i = 1, 3 do local t = {i}" .. ext(" @ (a, b)") .. "; owner.list[i] = t end",
            "    local c = owner.list[1] or a" .. ext(" @ a @ b"),
            extended and "    owner.close !@ (a, lifetime.scope)" or "    local _ = owner.close",
            "end"
        }, "\n")
    end
    return table.concat(out, "\n") .. "\n"
end

-- The lexer and the parser on `source`, against loadstring of `plain`.
local function add_parse(name, source, chunkname, plain)
    bench.add(name, function()
        parser.parse(lexer.tokenize(source, chunkname, true), chunkname)
    end, {
        baseline = function()
            loadstring(plain, "=" .. chunkname)
        end
    })
end

add_build("build/plain.lt", read_file("examples/plain.lt"), "examples/plain.lt")
add_build("build/generated-5000", generate_plain_lua(5000), "generated-5000.lua")
local largest = largest_lifetime_file()
local largest_source = read_file(largest)
add_build("build/lifetime-largest", largest_source, largest)
add_parse("parse/lifetime-largest", largest_source, largest, largest_source)
-- No build up front: a base without the extension raises inside the
-- benchmark, which the harness reports, and the other benchmarks of this
-- file still run.
local plain_5000 = generate_extended(5000, false)
assert(loadstring(plain_5000, "=extension-5000.lt"))
local extended_5000 = generate_extended(5000, true)
add_parse("parse/extension-5000", extended_5000, "extension-5000.lt", plain_5000)
-- `cli.build` on a file that uses the extension, against `loadstring` of
-- `plain`; no build up front, as above.
local function add_extension_build(name, source, chunkname, plain)
    bench.add(name, function()
        assert(cli.build(source, chunkname))
    end, {
        baseline = function()
            loadstring(plain, "=" .. chunkname)
        end
    })
end
add_extension_build("build/extension-5000", extended_5000, "extension-5000.lt", plain_5000)

-- A Teal chunk of exactly `lines` lines (a multiple of 10) in groups of
-- ten lines, typed and using the extension on most lines; with `teal`
-- false the same program as plain Lua (types and extension left out).
local function generate_teal(lines, teal)
    assert(lines % 10 == 0, "generate_teal: lines must be a multiple of 10")
    local function t(text)
        return teal and text or ""
    end
    local out = {}
    for k = 1, lines / 10 do
        out[#out + 1] = table.concat({
            string.format("do -- group %d", k),
            teal and string.format("    local record Owner%d id: integer list: {{integer}} closed: string child: Owner%d end", k, k) or string.format("    local Owner%d = {}", k),
            string.format("    local owner%s = {id = %d, list = {}}%s", t(": Owner" .. k), k, t(" as Owner" .. k)),
            "    local a, b" .. t(": {integer}, {string: string}") .. " = {1, 2}" .. t(" @ lifetime.scope") .. ", {name = \"b\"}" .. t(" @ (owner, lifetime.scope)"),
            "    local h = function(reason" .. t(": lifetime.Reason") .. ") owner.closed = reason end" .. t(" !@ owner"),
            teal and string.format("    function() print(%d) end !@ lifetime.scope", k) or string.format("    local _ = function() print(%d) end", k),
            "    for i = 1, 3 do local x" .. t(": {integer}") .. " = {i}" .. t(" @ (a, b)") .. "; owner.list[i] = x end",
            "    local c = owner.list[1] or a" .. t(" @ a @ b"),
            "    local n" .. t(": integer") .. " = #c + (owner.id" .. t(" as integer") .. ")" .. t(" // 1") .. "; owner.child = owner" .. t(" @ lifetime.pin(owner, a)") .. "; local _ = n" .. t(" is integer") .. ", h",
            "end"
        }, "\n")
    end
    return table.concat(out, "\n") .. "\n"
end
local plain_teal_5000 = generate_teal(5000, false)
assert(loadstring(plain_teal_5000, "=teal-5000.tlt"))
add_extension_build("build/teal-5000", generate_teal(5000, true), "teal-5000.tlt", plain_teal_5000)
-- Task 020: the constructor's `Name ':'` items in the Teal dialect, one
-- constructor per line, three such items in each.
local function generate_items(lines, format_line)
    local out = {}
    for k = 1, lines do
        out[k] = format_line(k)
    end
    return table.concat(out, "\n") .. "\n"
end
local typed_fields_5000 = generate_items(5000, function(k)
    return string.format("t%d = {n: integer = %d, s: {string} = {\"x\"}, f: function(): integer = function(): integer return %d end, r = %d}", k, k, k, k)
end)
local untyped_fields_5000 = generate_items(5000, function(k)
    return string.format("t%d = {n = %d, s = {\"x\"}, f = function() return %d end, r = %d}", k, k, k, k)
end)
assert(loadstring(untyped_fields_5000, "=teal-fields-5000.tlt"))
add_extension_build("build/teal-fields-5000", typed_fields_5000, "teal-fields-5000.tlt", untyped_fields_5000)
local method_items_5000 = generate_items(5000, function(k)
    return string.format("t%d = {r:get(), %d, s:put(%d), x = r:get \"y\"}", k, k, k)
end)
assert(loadstring(method_items_5000, "=teal-method-items-5000.tlt"))
add_extension_build("build/teal-method-items-5000", method_items_5000, "teal-method-items-5000.tlt", method_items_5000)
local generated_5000 = generate_plain_lua(5000)
assert(loadstring(generated_5000 .. "local last = {}\n", "=scope-at-end-5000.lt"))
add_extension_build("build/scope-at-end-5000", generated_5000 .. "local last = {} @ lifetime.scope\n", "scope-at-end-5000.lt", generated_5000 .. "local last = {}\n")
