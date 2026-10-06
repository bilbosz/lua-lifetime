-- lua-lifetime-dev-1.rockspec: the development rockspec for lua-lifetime.
-- Module name `lifetime`. Targets Lua 5.1 and LuaJIT (docs/02-semantics.md,
-- "Host"). Task 007 makes `luarocks make` install and run the command.
-- No license is declared yet: the human decides (xd has none either).
-- The teal-lifetime rockspec is a later addition to this repository
-- (docs/01-overview.md, "Rocks").
rockspec_format = "3.0"
package = "lua-lifetime"
version = "dev-1"
source = {
    url = "git+https://github.com/bilbosz/lua-lifetime.git"
}
description = {
    summary = "Ownership and destructors for Lua.",
    detailed = [[
Owned and scoped objects with destructors for Lua. x @ owner, x @ scope,
defer hooks. Cleanup runs in a defined order when the owner dies or the
scope exits. Transpiles to Lua 5.1 / LuaJIT.]],
    homepage = "https://github.com/bilbosz/lua-lifetime",
    labels = {"lifetime", "destructor", "ownership", "transpiler"}
}
dependencies = {
    "lua >= 5.1, < 5.2"
}
build = {
    type = "builtin",
    modules = {
        ["lifetime"] = "lifetime/init.lua",
        ["lifetime.lexer"] = "lifetime/lexer.lua",
        ["lifetime.parser"] = "lifetime/parser.lua",
        ["lifetime.emit"] = "lifetime/emit.lua",
        ["lifetime.cli"] = "lifetime/cli.lua"
    },
    install = {
        bin = {
            lifetime = "bin/lifetime"
        }
    }
}
