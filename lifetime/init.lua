-- lifetime/init.lua: the runtime, `require("lifetime")`.
--
-- This is the `lifetime` table of docs/02-semantics.md ("The `lifetime`
-- table") and the bookkeeping behind it, designed in docs/03-runtime.md:
-- state records inside the anchor, the cascade in the order of decision
-- 10, tombstones, the newproxy sentinel, scope records, hooks and
-- tokens.
--
-- Bootstrap skeleton. Task 002 fills in anchors, destroy, cascade,
-- tombstones and destroyerror; task 003 scopes and hooks; task 004
-- tokens, pin, alive and the sentinel.

local lifetime = {}

return lifetime
