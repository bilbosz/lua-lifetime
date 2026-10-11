-- teal-lifetime-dev-1.rockspec: the development rockspec for teal-lifetime,
-- the Teal front end of lua-lifetime (docs/01-overview.md, "Rocks"; task
-- 018). It depends on lua-lifetime for the runtime, the transpiler core
-- and the command, and on tl for the compiler `lifetime run` compiles the
-- generated Teal with. It installs the dialect module `lifetime.teal` and
-- the declaration file `lifetime/init.d.tl`, which tl finds next to the
-- runtime through the `?/init.lua` entry of the path. The command is
-- lua-lifetime's: `lifetime build FILE.tlt -o OUT.tl`, `lifetime run
-- FILE.tlt`.
-- No license is declared yet: the human decides (lua-lifetime has none).
rockspec_format = "3.0"
package = "teal-lifetime"
version = "dev-1"
source = {
    url = "git+https://github.com/bilbosz/lua-lifetime.git"
}
description = {
    summary = "Ownership and destructors for Teal.",
    detailed = [[
The Teal front end of lua-lifetime: Teal source with x @ owner, x @ scope
and cleanup !@ owner hooks (.tlt) transpiles to plain Teal, type-checked
and compiled by tl, and runs on the lua-lifetime runtime under Lua 5.1 /
LuaJIT.]],
    homepage = "https://github.com/bilbosz/lua-lifetime",
    labels = {"lifetime", "destructor", "ownership", "transpiler", "teal"}
}
dependencies = {
    "lua >= 5.1, < 5.2",
    "lua-lifetime",
    "tl >= 0.24.0"
}
build = {
    type = "builtin",
    modules = {
        ["lifetime.teal"] = "lifetime/teal.lua"
    },
    install = {
        lua = {
            -- Copied as lifetime/init.d.tl: a string key is a module path
            -- (the directory), and a file that is not .lua keeps its name.
            ["lifetime"] = "lifetime/init.d.tl"
        }
    }
}
