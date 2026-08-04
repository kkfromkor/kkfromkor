local root = assert(arg[1], "runtime directory is required")
local script_root = arg[2] or root

LOCATION_DECK = 0x1
LOCATION_HAND = 0x2
LOCATION_MZONE = 0x4
LOCATION_GRAVE = 0x10
LOCATION_REMOVED = 0x20
LOCATION_EXTRA = 0x40
LOCATION_SZONE = 0x8
LOCATION_FZONE = 0x100
POS_FACEUP_ATTACK = 0x1
POS_FACEUP_DEFENSE = 0x4
RESET_PHASE = 0x1000
PHASE_DRAW = 0x1
PHASE_END = 0x2
PHASE_DAMAGE = 0x4

Duel = {
	GetTurnPlayer=function() return 0 end,
}

opcg = {}
assert(dofile(root .. "/opcg_contract.lua"))
assert(dofile(root .. "/opcg_util.lua"))
local core = assert(dofile(root .. "/opcg_core.lua"))

function GetID()
	local source = debug.getinfo(2, "S").source
	local id = assert(source:match("c(%d+)%.lua$"), source)
	local name = "c" .. id
	local class = _G[name] or {}
	_G[name] = class
	return class, tonumber(id)
end

local fake_card = {
	GetControler=function() return 0 end,
	GetRace=function() return opcg.KIND.CHARACTER end,
}

local external = {
	ALLOW_UNLIMITED_DECK_COPIES=true,
	GAIN_EXTRA_TURN=true,
}
local function has_external(actions)
	for _, action in ipairs(actions or {}) do
		if external[action.op] then return true end
		if has_external(action.actions) or has_external(action.replacement_actions)
			or has_external(action.on_match) then return true end
		for _, option in ipairs(action.options or {}) do
			if has_external(option) then return true end
		end
	end
	return false
end

local cards, effects, supported, external_effects = 0, 0, 0, 0
local unexpected = {}
opcg.RegisterCard = function(_, definition)
	opcg.ValidateDefinition(definition)
	cards = cards + 1
	for _, effect in ipairs(definition.effects or {}) do
		effects = effects + 1
		local expected_external = has_external(effect.actions)
		local actual = core.EffectShapeSupported(effect, fake_card)
		if actual then supported = supported + 1 end
		if expected_external then external_effects = external_effects + 1 end
		if actual == expected_external then
			unexpected[#unexpected + 1] = definition.rules_id .. ":" .. effect.effect_id
		end
	end
	return definition
end

for id = 880000000, 880002004 do
	local filename = script_root .. "/c" .. id .. ".lua"
	local chunk, reason = loadfile(filename)
	assert(chunk, reason)
	chunk()
	local class = assert(_G["c" .. id], filename)
	assert(type(class.initial_effect) == "function", filename)
	class.initial_effect(fake_card)
end

assert(cards == 2005, ("expected 2005 cards, got %d"):format(cards))
assert(#unexpected == 0, "shape mismatch: " .. table.concat(unexpected, ","))
assert(external_effects == 5, ("expected 5 external effects, got %d"):format(external_effects))
assert(supported == effects - external_effects,
	("supported=%d effects=%d external=%d"):format(supported, effects, external_effects))

print(("opcg_all_definitions_shape: cards=%d effects=%d supported=%d external=%d")
	:format(cards, effects, supported, external_effects))
