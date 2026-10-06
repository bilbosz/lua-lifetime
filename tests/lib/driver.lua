-- tests/lib/driver.lua: runs one generated example for the conformance
-- runner (tests/conformance.lua) under the chunk name the contract
-- requires (examples/README.md):
--
--   <interpreter> tests/lib/driver.lua build/examples/NAME.lua examples/NAME.lt
--
-- Errors propagate uncaught, so the interpreter reports them as
-- `<interpreter>: <message>` and exits with status 1. Task 007 replaces
-- this driver with `lifetime run`.
local path, chunkname = arg[1], arg[2]
local f = assert(io.open(path, "rb"))
local source = f:read("*a")
f:close()
local chunk = assert(loadstring(source, "=" .. chunkname))
chunk()
