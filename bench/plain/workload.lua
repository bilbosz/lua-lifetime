-- bench/plain/workload.lua: a plain Lua chunk with no lifetime syntax,
-- the input of bench/bench-plain.lua. Running the chunk is one operation:
-- it builds objects with a metatable, calls closures and varargs
-- functions, sorts, formats strings, and catches an error, then returns a
-- checksum so the benchmark can check that the transpiled chunk computes
-- the same thing as the source loaded directly.
local Point = {}
Point.__index = Point

local function new_point(x, y)
    return setmetatable({x = x, y = y}, Point)
end

function Point:length2()
    return self.x * self.x + self.y * self.y
end

local function sum(...)
    local total = 0
    for i = 1, select("#", ...) do
        total = total + (select(i, ...))
    end
    return total
end

local function counter()
    local n = 0
    return function(step)
        n = n + (step or 1)
        return n
    end
end

local points = {}
for i = 1, 200 do
    points[i] = new_point(i % 17, (i * 7) % 23)
end
table.sort(points, function(a, b)
    return a:length2() < b:length2()
end)

local next_id = counter()
local parts = {}
for i = 1, #points, 10 do
    local p = points[i]
    parts[#parts + 1] = string.format("%d:%d,%d", next_id(), p.x, p.y)
end
local text = table.concat(parts, ";")

local checksum = 0
for i = 1, #points do
    checksum = checksum + points[i]:length2() * i
end
checksum = checksum + sum(1, 2, 3, 4, 5) + #text

local ok, message = pcall(error, {code = 7})
if not ok and type(message) == "table" then
    checksum = checksum + message.code
end

local words = {}
for word in ("alpha beta gamma delta epsilon"):gmatch("%a+") do
    words[#words + 1] = word:upper()
end
checksum = checksum + #table.concat(words)

return checksum
