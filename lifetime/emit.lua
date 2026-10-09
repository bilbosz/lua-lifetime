-- lifetime/emit.lua: code generation.
--
-- Turns the AST into Lua 5.1 source per docs/04-transpiler.md: the chunk
-- header, what `@` expands to, hooks (`!@`), block prologues and
-- epilogues on every exit path, the `pcall` wrapper for the error path,
-- nothing per function. Keeps every statement
-- on its source line. Exports `emit(ast)`.
--
-- Bootstrap skeleton. Task 001 implements the plain Lua round trip; task
-- 006 the extension.

local emit = {}

return emit
