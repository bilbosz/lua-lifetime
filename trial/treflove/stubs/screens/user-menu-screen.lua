-- Stub (not Treflove code): the user menu, a screen that lives while the
-- user is logged in. Its release() logs how deep the back stack is when
-- it dies, which pins whether the back entry went first.
---@class UserMenuScreen
local UserMenuScreen = class("UserMenuScreen")

---@param session Session
function UserMenuScreen:init(session)
    self._session = session
end

function UserMenuScreen:join_game()
end

function UserMenuScreen:release()
    trial_log("back stack depth " .. #app.backstack_manager._stack)
end

return UserMenuScreen
