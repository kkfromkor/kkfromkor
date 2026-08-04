local runtime_dir = assert(arg[1], "runtime directory is required")

REASON_DESTROY = 0x1
REASON_EFFECT = 0x2
REASON_BATTLE = 0x4
EFFECT_UPDATE_ATTACK = 1
EFFECT_UPDATE_LEVEL = 2
EFFECT_UPDATE_DEFENSE = 3
EFFECT_INDESTRUCTABLE = 40
EFFECT_INDESTRUCTABLE_EFFECT = 41
EFFECT_INDESTRUCTABLE_BATTLE = 42
EFFECT_TYPE_SINGLE = 0x1
EFFECT_TYPE_FIELD = 0x4
EFFECT_FLAG_SINGLE_RANGE = 0x1000
LOCATION_HAND = 0x2
LOCATION_MZONE = 0x4
LOCATION_GRAVE = 0x10
LOCATION_FZONE = 0x100

local registered = {}
local zone_cards = {
	[LOCATION_GRAVE] = {
		{ card_type="EVENT" }, { card_type="EVENT" }, { card_type="EVENT" },
		{ card_type="CHARACTER" }, { card_type="CHARACTER" },
	},
	[LOCATION_HAND] = {},
}

Effect = {}
function Effect.CreateEffect(card)
	local effect = {}
	function effect:SetType(value) self.type = value end
	function effect:SetCode(value) self.code = value end
	function effect:SetValue(value) self.value = value end
	function effect:SetCondition(value) self.condition = value end
	function effect:SetRange(value) self.range = value end
	function effect:SetProperty(value) self.property = value end
	function effect:SetTarget(value) self.target = value end
	function effect:SetTargetRange(a, b) self.target_range = { a, b } end
	function effect:SetCountLimit() end
	function effect:GetHandler() return card end
	function effect:GetHandlerPlayer() return card:GetControler() end
	return effect
end

Duel = {
	GetTurnCount=function() return 1 end,
	GetTurnPlayer=function() return 0 end,
	GetMatchingGroupCount=function(predicate, _, location)
		local count = 0
		for _, card in ipairs(zone_cards[location] or {}) do
			if predicate(card) then count = count + 1 end
		end
		return count
	end,
}

local function compile_filter(filter)
	filter = filter or {}
	local known = { card_type=true, attribute=true }
	for key in pairs(filter) do if not known[key] then return nil end end
	return function(card)
		if filter.card_type and card.card_type ~= filter.card_type then return false end
		if filter.attribute and card.attribute ~= filter.attribute then return false end
		return true
	end
end

opcg = {
	CompileFilter=function(filter) return compile_filter(filter) end,
	KindPredicate=function(kind)
		if kind == "CHARACTER" then return function(card) return card.card_type == "CHARACTER" end end
		return nil
	end,
	ResolvePlayer=function(_, context) return context.player end,
	IsEvent=function() return false end,
	IsCharacter=function() return true end,
	IsLeader=function() return false end,
	IsStage=function() return false end,
	GetLeader=function() return nil end,
	GetAttachedDon=function() return 99 end,
	RestedDon=function() return 5 end,
	KEYWORD_EFFECT={},
	effect_queue=nil,
	runtime={
		can_resolve=function() return true end,
		resolve=function() end,
		dispatch=function() end,
	},
	battle={ register_attack_action=function() end },
	rules=nil,
}

local card = {}
function card:GetControler() return 0 end
function card:RegisterEffect(effect) registered[#registered + 1] = effect end
function card:GetHandler() return self end

setmetatable(_G, {
	__index=function(_, key)
		if type(key) == "string" and key:match("^%u[%u%d_]+$") then return 0x40000000 end
	end,
})

local C = assert(loadfile(runtime_dir .. "/opcg_core.lua"))()

local assertions = 0
local function check(value, message)
	assert(value, message)
	assertions = assertions + 1
end
local function bind(action, timings)
	registered = {}
	C.BindCard(card, {
		effects={{
			actions={ action },
			conditions={},
			costs={},
			timings=timings or { "CONTINUOUS" },
			effect_id="TEST",
		}},
	})
	return registered
end
local self_selector = { owner="YOU", kind="SELF", count=1, mode="UP_TO" }

local effects = bind({
	op="MODIFY_POWER_PER_COUNT",
	player="YOU",
	selector=self_selector,
	source="TRASH",
	filter={ card_type="EVENT" },
	divisor=2,
	amount_per=1000,
	duration="WHILE_CONDITION",
})
check(#effects == 1, "filtered per-count effect was not registered")
check(effects[1].code == EFFECT_UPDATE_ATTACK, "wrong per-count effect code")
check(effects[1].value(effects[1], card) == 1000,
	"per-count ignored its EVENT filter (3 events / 2 * 1000 must be 1000)")

effects = bind({
	op="CANNOT_BE_KO",
	selector=self_selector,
	reason="OPPONENT_EFFECT",
	duration="WHILE_CONDITION",
})
check(#effects == 1 and effects[1].code == EFFECT_INDESTRUCTABLE_EFFECT,
	"opponent-effect immunity was not registered")
check(effects[1].value(effects[1], {}, 1) == true,
	"opponent effect should be blocked")
check(effects[1].value(effects[1], {}, 0) == false,
	"own effect must not be blocked")

effects = bind({
	op="CANNOT_BE_KO",
	selector=self_selector,
	reason="BATTLE",
	attacker_filter={ attribute="SLASH" },
	duration="WHILE_CONDITION",
})
check(#effects == 1 and effects[1].code == EFFECT_INDESTRUCTABLE_BATTLE,
	"filtered battle immunity was not registered")
check(effects[1].value(effects[1], { attribute="SLASH" }) == true,
	"matching battle opponent should be blocked")
check(effects[1].value(effects[1], { attribute="STRIKE" }) == false,
	"non-matching battle opponent must not be blocked")

effects = bind({
	op="CANNOT_BE_KO",
	selector=self_selector,
	reason="CHARACTER_EFFECT",
	source_filter={ attribute_neq="SPECIAL" },
	duration="WHILE_CONDITION",
})
check(#effects == 0, "unsupported source-filter immunity must fail closed")

effects = bind({
	op="CANNOT_BE_KO",
	selector=self_selector,
	reason="OPPONENT_EFFECT",
	limit="ONCE_PER_TURN",
	duration="WHILE_CONDITION",
})
check(#effects == 1 and effects[1].code == EFFECT_INDESTRUCTABLE_EFFECT,
	"once-per-turn continuous immunity was not registered")

effects = bind({
	op="CANNOT_BE_KO",
	selector=self_selector,
	reason="BATTLE",
	duration="THIS_TURN",
}, { "COUNTER" })
check(#effects == 0, "non-continuous immunity must fail closed")

print(("opcg_continuous_extensions: %d assertions passed"):format(assertions))
