-- Stub (not Treflove code): the login screen shown after a logout.
---@class LoginScreen
local LoginScreen = class("LoginScreen")

---@param login Login
function LoginScreen:init(login)
    self._login = login
end

return LoginScreen
