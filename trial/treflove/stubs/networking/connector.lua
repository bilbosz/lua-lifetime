-- Stub (not Treflove code): the connector's threads and sockets are
-- outside the slice; the trial adds connections by hand.
---@class Connector
local Connector = class("Connector")

---@param address string
---@param port string
function Connector:init(address, port)
    self._address = address
    self._port = port
end

---@param connection_manager ConnectionManager
function Connector:start(connection_manager)
    self._connection_manager = connection_manager
end

function Connector:remove_thread()
end

return Connector
