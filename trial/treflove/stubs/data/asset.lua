-- Stub (not Treflove code): data/asset-manager.lua requires it; the trial
-- never mounts or reads an asset.
---@class Asset
local Asset = class("Asset")

---@param path string
---@param is_server boolean
function Asset:init(path, is_server)
    self._path = path
    self._is_server = is_server
end

return Asset
