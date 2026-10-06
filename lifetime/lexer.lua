-- lifetime/lexer.lua: the lexer.
--
-- Lua 5.1 tokens plus `@` and the keywords of docs/04-transpiler.md,
-- "Grammar". Exports `tokenize(source, chunkname)`, returning an array of
-- tokens {type, value, line}; a malformed token raises
-- `chunkname:line: <message>` in Lua's own wording.
--
-- Bootstrap skeleton. Task 001 implements Lua 5.1; task 005 adds the
-- extension tokens.

local lexer = {}

return lexer
