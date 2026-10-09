-- lifetime/parser.lua: the parser.
--
-- A recursive-descent parser for the grammar of docs/04-transpiler.md,
-- "Grammar": Lua 5.1 plus `@` with the list form, the hook operator `!@`,
-- and `scope` as an anchor. Exports `parse(tokens, chunkname)`
-- returning a plain table AST with a `line` on every node; a syntax error
-- raises `chunkname:line: <message> near '<token>'`.
--
-- Bootstrap skeleton. Task 001 implements Lua 5.1; task 005 adds the
-- extension grammar.

local parser = {}

return parser
