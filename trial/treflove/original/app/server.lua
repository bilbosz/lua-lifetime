-- Excerpt of Treflove's app/server.lua: the `_sessions` table of
-- Server:init and the two connection callbacks of Server:load, as a
-- function over the app. The rest of the class (App, screens, the save
-- file) is outside the slice. The callbacks are Treflove's, unchanged.
local Session = require("game.session")

---@class TrialServer
local Server = {}

---@param self AppMock
function Server.load(self)
    self._sessions = {}
    self.connection_manager:start(function(connection)
        self._sessions[connection] = Session(connection)
    end, function(connection)
        self._sessions[connection]:release()
        self._sessions[connection] = nil
    end)
end

return Server
