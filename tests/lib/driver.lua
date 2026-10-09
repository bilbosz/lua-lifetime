-- tests/lib/driver.lua: runs one generated example for the conformance
-- runner (tests/conformance.lua) under the chunk name the contract
-- requires (examples/README.md):
--
--   <interpreter> tests/lib/driver.lua build/examples/NAME.lua examples/NAME.lt
--
-- Run from the repository root. The generated chunk requires `lifetime`
-- itself, through its header (docs/04-transpiler.md, "The generated chunk
-- header"), so the driver puts the repository's modules on
-- `package.path`: the interpreters' default path has `./?.lua` but not
-- `./?/init.lua`, where `lifetime` is.
--
-- The chunk is called through the runtime's `pcall`, required first, as
-- docs/04-transpiler.md, "The error path: unwinding at the catch site",
-- says an embedding host does ("an embedding host that loads the chunk
-- itself gets the same by calling it through `pcall` after requiring
-- `lifetime`"), so that an uncaught error unwinds the main scope before
-- it is reported. The error is then raised again, uncaught, so the
-- interpreter reports it as `<interpreter>: <message>` and exits with
-- status 1. Task 007 replaces this driver with `lifetime run`.
package.path = "./?.lua;./?/init.lua;" .. package.path
require("lifetime")
local path, chunkname = arg[1], arg[2]
local f = assert(io.open(path, "rb"))
local source = f:read("*a")
f:close()
local chunk = assert(loadstring(source, "=" .. chunkname))
local ok, err = pcall(chunk)
if not ok then
    error(err, 0)
end
