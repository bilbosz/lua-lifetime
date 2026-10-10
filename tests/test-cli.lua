-- tests/test-cli.lua: lifetime/cli.lua's `build` (tasks 001 and 006), the
-- pipeline of docs/04-transpiler.md, "Pipeline".
local test = require("tests.lib.test")
local cli = require("lifetime.cli")

test.suite("cli.build")

test.case("a plain chunk builds to itself modulo whitespace", function()
    test.assert_eq(cli.build("local x  =  1\n\n-- c\nprint( x )\n", "a.lt"), "local x = 1\n\n\nprint(x)\n")
end)

test.case("a syntax error returns nil and the message", function()
    local output, message = cli.build("x @ ()", "a.lt")
    test.assert_eq(output, nil)
    test.assert_eq(message, "a.lt:1: empty anchor list near ')'")
    output, message = cli.build("\nlocal z = x @ y + 1", "examples/b.lt")
    test.assert_eq(output, nil)
    test.assert_eq(message, "examples/b.lt:2: unexpected symbol near '+'")
    output, message = cli.build("if a != b then end", "a.lt")
    test.assert_eq(output, nil)
    test.assert_eq(message, "a.lt:1: unexpected symbol near '!' (use '~=' for inequality)")
end)

test.case("the extension builds to calls of the runtime, positions under the chunk name", function()
    -- Task 006 replaced task 005's placeholder, which wrote the extension
    -- back in its own spelling (docs/04-transpiler.md, "The generated
    -- chunk header", "What `@` expands to", "Blocks").
    test.assert_eq(cli.build("local x  =  {} @ lifetime.scope\nf !@ ( a,b )\n", "a.lt"), table.concat({
        "local lifetime = require(\"lifetime\"); local __lt_attach, __lt_hook, __lt_enter, __lt_exit = lifetime.attach, lifetime.hook, lifetime.enter, lifetime.exit;",
        " local __s1 = __lt_enter(\"a.lt:3\"); local x = __lt_attach({}, false, __s1)\n",
        "__lt_hook(f, nil, a, b)\n",
        "__lt_exit(__s1, \"a.lt:3\");"
    }))
end)

test.case("a goto into a block with a scope record returns nil and the message", function()
    -- docs/04-transpiler.md, "Blocks": "A `goto` into a block that needs a
    -- record is a compile error ("jumps into the scope of a lifetime")."
    local output, message = cli.build("goto inside\ndo\n    local r = {} @ lifetime.scope\n    ::inside::\nend\n", "a.lt")
    test.assert_eq(output, nil)
    test.assert_eq(message, "a.lt:1: <goto inside> jumps into the scope of a lifetime")
end)

test.case("a malformed token returns nil and the message", function()
    local output, message = cli.build("x = 0x", "a.lt")
    test.assert_eq(output, nil)
    test.assert_eq(message, "a.lt:1: malformed number near '0x'")
end)

test.case("the output of examples/plain.lt runs under its chunk name", function()
    local f = assert(io.open("examples/plain.lt", "rb"))
    local source = f:read("*a")
    f:close()
    local output = assert(cli.build(source, "examples/plain.lt"))
    local chunk = assert(loadstring(output, "=examples/plain.lt"))
    test.assert_eq(type(chunk), "function")
end)

test.case("a syntax error is recognised by its marker, not by the chunkname prefix", function()
    -- Task 001, review round 2: a transpiler bug whose message happens to
    -- start with the chunkname propagates; it is not a syntax error.
    local emit = require("lifetime.emit")
    local parser = require("lifetime.parser")
    local saved_emit, saved_parse = emit.emit, parser.parse
    local ok, err = pcall(function()
        emit.emit = function()
            error("a.lt:1: attempt to index a nil value", 0)
        end
        test.assert_eq(test.assert_error(function()
            cli.build("local x = 1\n", "a.lt")
        end), "a.lt:1: attempt to index a nil value")
        emit.emit = saved_emit
        parser.parse = function()
            error("a.lt:2: <goto x> jumps into the scope of a lifetime, and more", 0)
        end
        test.assert_eq(test.assert_error(function()
            cli.build("local x = 1\n", "a.lt")
        end), "a.lt:2: <goto x> jumps into the scope of a lifetime, and more")
    end)
    emit.emit, parser.parse = saved_emit, saved_parse
    assert(ok, err)
    -- The real errors of every stage still come back as nil and a message,
    -- whatever the chunkname looks like.
    test.assert_deep_eq({cli.build("x = 0x", "lifetime/emit.lua")}, {nil, "lifetime/emit.lua:1: malformed number near '0x'"})
    test.assert_deep_eq({cli.build("x @ ()", "lifetime/emit.lua")}, {nil, "lifetime/emit.lua:1: empty anchor list near ')'"})
    test.assert_deep_eq({cli.build("goto l\ndo local r = {} @ lifetime.scope ::l:: end", "x:1")}, {nil, "x:1:1: <goto l> jumps into the scope of a lifetime"})
    -- A label with bytes >= 128, which the lexer accepts in names (task
    -- 007, review round 1, F1).
    test.assert_deep_eq({cli.build("goto lä\ndo local r = {} @ lifetime.scope ::lä:: end", "x")}, {nil, "x:1: <goto lä> jumps into the scope of a lifetime"})
end)

------------------------------------------------------------------------
-- The command: bin/lifetime under every interpreter found (task 007;
-- docs/04-transpiler.md, "The command").
------------------------------------------------------------------------

test.suite("lifetime command")

local conformance = require("tests.conformance")
local INTERPRETERS = conformance.find_interpreters()
local SCRATCH = "build/test-cli"

local function quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
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

os.execute("mkdir -p " .. quote(SCRATCH))

-- Run a shell command line through io.popen; its standard error goes to
-- a file unless the command redirects it. Returns stdout, stderr and the
-- exit status, the same under lua5.1 and luajit (whose `close` results
-- differ).
local function shell(command)
    local err_path = os.tmpname()
    local p = assert(io.popen("{ " .. command .. "; } 2>" .. quote(err_path) .. "; echo \"<status $?>\""))
    local out = p:read("*a")
    p:close()
    local stderr = read_file(err_path) or ""
    os.remove(err_path)
    local status = tonumber(out:match("<status (%d+)>\n$"))
    return (out:gsub("<status %d+>\n$", "")), stderr, status
end

-- `<interpreter> bin/lifetime <args>`, from the repository root.
local function lifetime(interpreter, args)
    return shell(interpreter .. " bin/lifetime " .. args)
end

local USAGE = "usage: lifetime build FILE -o OUT\n       lifetime run FILE [ARGS]\n"

test.case("there is an interpreter to run bin/lifetime with", function()
    test.assert_true(#INTERPRETERS > 0)
end)

for _, interpreter in ipairs(INTERPRETERS) do
    local function case(name, fn)
        test.case(name .. " (" .. interpreter .. ")", fn)
    end

    case("build -o - writes cli.build's output to stdout", function()
        -- Test case 3.
        for _, path in ipairs({"examples/plain.lt", "examples/scope_exit.lt"}) do
            local out, err, status = lifetime(interpreter, "build " .. path .. " -o -")
            test.assert_eq(err, "")
            test.assert_eq(status, 0)
            test.assert_eq(out, assert(cli.build(read_file(path), path)))
        end
    end)

    case("build FILE -o OUT writes the file, the option before or after FILE", function()
        local target = SCRATCH .. "/out-" .. interpreter .. ".lua"
        local expected = assert(cli.build(read_file("examples/unwind.lt"), "examples/unwind.lt"))
        os.remove(target)
        test.assert_deep_eq({lifetime(interpreter, "build examples/unwind.lt -o " .. target)}, {"", "", 0})
        test.assert_eq(read_file(target), expected)
        os.remove(target)
        test.assert_deep_eq({lifetime(interpreter, "build -o " .. target .. " examples/unwind.lt")}, {"", "", 0})
        test.assert_eq(read_file(target), expected)
    end)

    case("a usage error prints the usage on stderr and exits 2", function()
        -- Test case 4: a missing -o is a usage error.
        for _, args in ipairs({"build examples/plain.lt", "build -o -", "build examples/plain.lt -o", "build a.lt b.lt -o -", "build a.lt -o x -o y", "run", "", "frobnicate examples/plain.lt"}) do
            test.assert_deep_eq({lifetime(interpreter, args)}, {"", USAGE, 2}, "lifetime " .. args)
        end
    end)

    case("a syntax error prints FILE:LINE: <message> and exits 1", function()
        -- Test case 4: build reports the shape of docs/04, "The command";
        -- run reports it as the standalone interpreter reports a load
        -- error, behind its own name.
        local path = SCRATCH .. "/syntax-error.lt"
        write_file(path, "local x = 1\nx @ ()\n")
        test.assert_deep_eq({lifetime(interpreter, "build " .. path .. " -o -")}, {"", path .. ":2: empty anchor list near ')'\n", 1})
        test.assert_deep_eq({lifetime(interpreter, "run " .. path)}, {"", "lifetime: " .. path .. ":2: empty anchor list near ')'\n", 1})
        write_file(path, "local x = 0x\n")
        test.assert_deep_eq({lifetime(interpreter, "build " .. path .. " -o -")}, {"", path .. ":1: malformed number near '0x'\n", 1})
    end)

    case("a file that cannot be read is reported with exit status 1", function()
        local out, err, status = lifetime(interpreter, "run " .. SCRATCH .. "/missing.lt")
        test.assert_eq(out, "")
        test.assert_eq(err, "lifetime: cannot open " .. SCRATCH .. "/missing.lt: No such file or directory\n")
        test.assert_eq(status, 1)
        out, err, status = lifetime(interpreter, "build " .. SCRATCH .. "/missing.lt -o -")
        test.assert_eq(out, "")
        test.assert_eq(err, "lifetime: cannot open " .. SCRATCH .. "/missing.lt: No such file or directory\n")
        test.assert_eq(status, 1)
    end)

    case("run FILE a b: arg, the chunk's ..., the chunk name FILE; the return value is ignored", function()
        -- The second criterion: arg[0] == FILE, arg[1] == "a", the chunk
        -- name FILE, exit status 0 although the chunk returns values.
        local out, err, status = lifetime(interpreter, "run tests/fixtures/args.lt a b")
        test.assert_eq(err, "")
        test.assert_eq(status, 0)
        test.assert_eq(out, table.concat({
            "arg[0]\ttests/fixtures/args.lt",
            "arg[1]\ta",
            "arg[2]\tb",
            "#arg\t2",
            "arg[-1]\trun",
            "arg[-2]\tbin/lifetime",
            "...\t2\ta\tb",
            "source\t@tests/fixtures/args.lt",
            "position\ttests/fixtures/args.lt:13: here",
            "scoped\ttrue",
            ""
        }, "\n"))
    end)

    case("run keeps the line numbers of a file that starts with #!", function()
        local path = SCRATCH .. "/shebang.lt"
        write_file(path, "#!/usr/bin/env lifetime\nlocal r = {} @ lifetime.scope\nerror(\"third line\")\n")
        local out, err, status = lifetime(interpreter, "run " .. path)
        test.assert_eq(out, "")
        test.assert_eq(err:match("^[^\n]*"), "lifetime: " .. path .. ":3: third line")
        test.assert_eq(status, 1)
    end)

    case("an uncaught error unwinds every open scope, the main scope last, then is reported", function()
        -- Test case 2, and the sentence of docs/04 most likely to be
        -- misread: the cascade runs before the message is printed. Both
        -- streams go into one pipe; the report flushes stdout before it
        -- writes, so the pipe's order is the order of events.
        local out, _, status = shell(interpreter .. " bin/lifetime run examples/main_scope_error.lt 2>&1")
        test.assert_eq(status, 1)
        test.assert_eq(out, table.concat({
            "calling with\tfirst\tsecond",
            "raising in\tinner",
            "destroy inner (anchor)",
            "destroy second (anchor)",
            "destroy first (anchor)",
            "lifetime: examples/main_scope_error.lt:23: x",
            "stack traceback:",
            "\t[C]: in function 'error'",
            "\texamples/main_scope_error.lt:23: in function 'fail'",
            "\texamples/main_scope_error.lt:27: in main chunk",
            ""
        }, "\n"))
    end)

    case("a non-string error object is reported through __tostring or by its type", function()
        local path = SCRATCH .. "/error-object.lt"
        write_file(path, "error(setmetatable({}, {__tostring = function() return 'custom' end}))\n")
        local _, err, status = lifetime(interpreter, "run " .. path)
        test.assert_eq(err:match("^[^\n]*"), "lifetime: custom")
        test.assert_eq(status, 1)
        write_file(path, "error({})\n")
        _, err, status = lifetime(interpreter, "run " .. path)
        test.assert_eq(err:match("^[^\n]*"), "lifetime: (error object is a table value)")
        test.assert_eq(status, 1)
    end)

    case("bin/lifetime runs from outside the checkout with the checkout's modules", function()
        -- What the rockspec's installed command must do (run from a
        -- directory outside the checkout), on the checkout's script, which
        -- puts the directory above bin/ on package.path.
        local root = assert(os.getenv("PWD"), "PWD is not set")
        local elsewhere = os.tmpname()
        os.remove(elsewhere)
        os.execute("mkdir -p " .. quote(elsewhere))
        local out, err, status = shell("cd " .. quote(elsewhere) .. " && " .. interpreter .. " " .. quote(root .. "/bin/lifetime") .. " run " .. quote(root .. "/examples/plain.lt"))
        os.execute("rmdir " .. quote(elsewhere))
        test.assert_eq(err, "")
        test.assert_eq(status, 0)
        test.assert_eq(out, read_file("examples/plain.lt.expected"))
    end)

    case("the main scope dies at the chunk's end with reason anchor, the registered globals at exit", function()
        -- Test case 1 (examples/exit_order.lt, also run by the conformance
        -- suite): the main scope dies at the chunk's end, then the globals
        -- through task 004's sentinels, with reason "exit" because `run`
        -- has called `lifetime.set_exiting(true)`.
        local out, err, status = lifetime(interpreter, "run examples/exit_order.lt")
        test.assert_eq(err, "")
        test.assert_eq(status, 0)
        test.assert_eq(out, read_file("examples/exit_order.lt.expected"))
    end)

    case("examples calling lifetime.destroy and lifetime.discard run as expected with no builtin", function()
        -- Task 016, test case 5 (also run by the conformance suite): the
        -- header binds `lifetime` only, and `lifetime.destroy` passed as a
        -- value (examples/destroy_errors.lt) is the runtime's
        -- (docs/05-decisions.md, "`destroy` and `discard` are spelled
        -- `lifetime.destroy` and `lifetime.discard`").
        for _, path in ipairs({"examples/explicit_destroy.lt", "examples/hooks.lt", "examples/destroy_errors.lt"}) do
            local out, err, status = lifetime(interpreter, "run " .. path)
            test.assert_eq(err, "", path)
            test.assert_eq(status, 0, path)
            test.assert_eq(out, read_file(path .. ".expected"), path)
            local built = assert(cli.build(read_file(path), path))
            test.assert_false(built:find("local destroy", 1, true), path)
            test.assert_false(built:find("local discard", 1, true), path)
        end
    end)
end

------------------------------------------------------------------------
-- The rockspec (task 007; docs/01-overview.md, "Rocks"). `luarocks make`
-- itself is not run here: the suite has no dependencies.
------------------------------------------------------------------------

test.suite("rockspec")

-- The rockspec's fields, read as luarocks reads them: a Lua chunk run in
-- an empty environment.
local function load_rockspec(path)
    local chunk = assert(loadfile(path))
    local env = {}
    setfenv(chunk, env)
    chunk()
    return env
end

test.case("lua-lifetime-dev-1.rockspec installs every module and the command", function()
    local spec = load_rockspec("lua-lifetime-dev-1.rockspec")
    test.assert_eq(spec.package, "lua-lifetime")
    test.assert_eq(spec.version, "dev-1")
    test.assert_eq(spec.description.summary, "Ownership and destructors for Lua.")
    test.assert_deep_eq(spec.dependencies, {"lua >= 5.1, < 5.2"})
    test.assert_eq(spec.build.type, "builtin")
    test.assert_deep_eq(spec.build.install.bin, {lifetime = "bin/lifetime"})
    -- Every lifetime/*.lua file is a module of the rock under its require
    -- name, and every module's file exists.
    local expected = {}
    local p = assert(io.popen("ls -1 lifetime/*.lua"))
    for path in p:lines() do
        local stem = path:match("^lifetime/(.+)%.lua$")
        expected[stem == "init" and "lifetime" or "lifetime." .. stem] = path
    end
    p:close()
    test.assert_deep_eq(spec.build.modules, expected)
    test.assert_true(read_file("bin/lifetime") ~= nil)
end)

for _, interpreter in ipairs(INTERPRETERS) do
    test.case("the command runs from an installed layout, outside the checkout (" .. interpreter .. ")", function()
        -- The layout `luarocks make` gives a builtin rock: the modules
        -- under the tree's share/lua/5.1 (`lifetime` as lifetime/init.lua),
        -- the script in the rock's own bin/, run by a wrapper that puts
        -- the tree on package.path. Simulated by hand, since the suite
        -- does not depend on luarocks; the script must then take the
        -- modules from the path, not from a checkout.
        local root = assert(os.getenv("PWD"), "PWD is not set")
        local tree = os.tmpname()
        os.remove(tree)
        local share = tree .. "/share/lua/5.1"
        local rock_bin = tree .. "/lib/luarocks/rocks-5.1/lua-lifetime/dev-1/bin"
        local elsewhere = tree .. "/elsewhere"
        os.execute("mkdir -p " .. quote(share .. "/lifetime") .. " " .. quote(rock_bin) .. " " .. quote(elsewhere))
        local spec = load_rockspec("lua-lifetime-dev-1.rockspec")
        for name, file in pairs(spec.build.modules) do
            local target = share .. "/" .. name:gsub("%.", "/") .. (file:match("init%.lua$") and "/init.lua" or ".lua")
            write_file(target, read_file(file))
        end
        write_file(rock_bin .. "/lifetime", read_file("bin/lifetime"))
        local path = share .. "/?.lua;" .. share .. "/?/init.lua;"
        local out, err, status = shell("cd " .. quote(elsewhere) .. " && " .. interpreter .. " -e " .. quote("package.path=" .. string.format("%q", path) .. "..package.path") .. " " .. quote(rock_bin .. "/lifetime") .. " run " .. quote(root .. "/examples/plain.lt"))
        os.execute("rm -rf " .. quote(tree))
        test.assert_eq(err, "")
        test.assert_eq(status, 0)
        test.assert_eq(out, read_file("examples/plain.lt.expected"))
    end)
end
