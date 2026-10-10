-- Stub (not Treflove code): utils/utils.lua needs `socket.gettime` only,
-- as Treflove's own tests/run.lua stubs it under plain LuaJIT.
return {
    gettime = function()
        return os.clock()
    end
}
