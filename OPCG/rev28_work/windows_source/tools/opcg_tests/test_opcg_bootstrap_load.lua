local root = assert(arg[1], "runtime directory is required")

aux = {
	Stringid=function(code, index) return code * 16 + index end,
}
Duel = {}
function Duel.LoadScript(name)
	return assert(loadfile(root .. "/" .. name))()
end

setmetatable(_G, {
	__index=function(t, key)
		if type(key) == "string" and key:match("^%u[%u%d_]+$") then
			rawset(t, key, 0x40000000)
			return 0x40000000
		end
	end,
})

local loaded = assert(dofile(root .. "/opcg_bootstrap.lua"))
assert(loaded == opcg)
assert(OPCGCore and type(OPCGCore.GetSupportedOperations) == "function")
assert(opcg.contract_ops and type(opcg.contract_ops.execute) == "function")
assert(opcg.runtime and opcg.runtime.adapter)

print("opcg_bootstrap_load: passed")
