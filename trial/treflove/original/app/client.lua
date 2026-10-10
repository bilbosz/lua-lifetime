-- Excerpt of Treflove's app/client.lua: the two connection callbacks of
-- Client:load, as a function over the app. The connecting screen and the
-- quit entry of the back stack are outside the slice. The callbacks are
-- Treflove's, unchanged.
local Session = require("game.session")

---@class TrialClient
local Client = {}

---@param self AppMock
function Client.load(self)
    self.connection_manager:start(function(connection)
        self.session = Session(connection)
    end, function()
        self.session:release()
        self.session = nil
        self.data = nil
    end)
end

return Client
