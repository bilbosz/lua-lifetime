-- https://luacheck.readthedocs.io/en/stable/index.html
-- Style copied from Treflove's .luacheckrc where it fits: no line-length
-- limit, unused arguments allowed on interface functions.
max_line_length = false
max_comment_line_length = false

-- 212 (unused argument): placeholder and interface functions keep their
-- full parameter lists as documentation even when the body ignores them.
ignore = {"212"}

-- Lua 5.1 and LuaJIT are the targets (docs/02-semantics.md, "Host"):
-- `newproxy`, `unpack`, `loadstring`, `setfenv` are 5.1's; `jit` is
-- LuaJIT's and is only used where present (the transpiler's parser and
-- emitter call `jit.off`; the runtime and generated code never use it).
std = "lua51"
read_globals = {"jit"}

exclude_files = {
    "build/**",
    ".lua_modules/**"
}

files["trial/treflove/stubs"] = {
    -- The trial's stand-ins for Treflove modules outside the slice (task
    -- 009) run in the environment of trial/treflove/harness.lua, where
    -- Treflove's globals live.
    read_globals = {"class", "app", "trial_log"}
}

files["bin/lifetime"] = {
    -- The command script: arg is set by the interpreter.
    read_globals = {"arg"}
}
