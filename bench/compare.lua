-- bench/compare.lua: compare a branch's benchmark output with a base's
-- over pairings of alternating runs. From the repository root:
--
--   lua5.1 bench/compare.lua BRANCH-1.txt BASE-1.txt [BRANCH-2.txt BASE-2.txt ...]
--
-- Every file is bench/run.lua output; each BRANCH/BASE pair is one
-- pairing (`make bench BASE=` passes two: branch, base, branch, base).
-- Prints one line per benchmark of the branch,
-- `name<TAB>branch ns/op<TAB>base ns/op<TAB>pairing 1<TAB>...<TAB>branch/base<TAB>mark`,
-- with mark SLOWER when every pairing exceeds the threshold of
-- bench/README.md (bench.compare in bench/lib/bench.lua). Exit status 2
-- on a usage error, 1 when a file cannot be read.
package.path = "./?.lua;./?/init.lua;" .. package.path
local bench = require("bench.lib.bench")

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then
        io.stderr:write("bench/compare.lua: " .. tostring(err) .. "\n")
        os.exit(1)
    end
    local data = f:read("*a")
    f:close()
    return data
end

if #arg < 2 or #arg % 2 ~= 0 then
    io.stderr:write("usage: bench/compare.lua BRANCH-1.txt BASE-1.txt [BRANCH-2.txt BASE-2.txt ...]\n")
    os.exit(2)
end

local pairings = {}
for k = 1, #arg, 2 do
    pairings[#pairings + 1] = {read_file(arg[k]), read_file(arg[k + 1])}
end

for _, line in ipairs(bench.compare(pairings)) do
    print(line)
end
