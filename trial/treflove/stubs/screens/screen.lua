-- Stub (not Treflove code): the control tree behind a screen is outside
-- the slice.
---@class Screen
local Screen = class("Screen")

function Screen:init()
end

---@param ... any
function Screen:show(...)
end

function Screen:hide()
end

---@param w number
---@param h number
function Screen:on_resize(w, h)
end

return Screen
