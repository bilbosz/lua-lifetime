-- bench/compare.lua: compare a branch's benchmark output with a base's.
-- From the repository root:
--
--   lua5.1 bench/compare.lua BRANCH.txt BASE.txt
--
-- Both files are bench/run.lua output. Prints one line per benchmark of
-- the branch, `name<TAB>branch ns/op<TAB>base ns/op<TAB>branch/base<TAB>mark`,
-- with mark SLOWER beyond the threshold of bench/README.md.
package.path = "./?.lua;./?/init.lua;" .. package.path
local bench = require("bench.lib.bench")

local function read_file(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return data
end

local branch_path, base_path = arg[1], arg[2]
if not branch_path or not base_path then
    io.stderr:write("usage: bench/compare.lua BRANCH.txt BASE.txt\n")
    os.exit(2)
end

for _, line in ipairs(bench.compare(read_file(branch_path), read_file(base_path))) do
    print(line)
end
