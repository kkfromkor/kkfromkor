local root = assert(arg[1], "runtime directory is required")

local assertions = 0
local function equal(actual, expected, label)
	assertions = assertions + 1
	if actual ~= expected then
		error(("%s: expected %s, got %s"):format(label, tostring(expected), tostring(actual)))
	end
end
local function count_keys(value)
	local count = 0
	for _ in pairs(value) do count = count + 1 end
	return count
end

LOCATION_HAND = 0x2
LOCATION_MZONE = 0x4
LOCATION_GRAVE = 0x10
LOCATION_EXTRA = 0x40
LOCATION_FZONE = 0x100
PHASE_DRAW = 1
PHASE_STANDBY = 2
PHASE_END = 4
PHASE_DAMAGE = 8
RESET_PHASE = 0x1000
REASON_EFFECT = 0x40
REASON_BATTLE = 0x20
REASON_DESTROY = 0x1
REASON_COST = 0x80
REASON_DISCARD = 0x4000
EFFECT_CANNOT_ATTACK = 85
EFFECT_DISABLE = 1
EFFECT_DISABLE_EFFECT = 2
EFFECT_CANNOT_DRAW = 3
EFFECT_CANNOT_LOSE_DECK = 4
EFFECT_UPDATE_ATTACK = 5
EFFECT_UPDATE_LEVEL = 6
EFFECT_UPDATE_DEFENSE = 7
EFFECT_SET_BASE_ATTACK = 8
EFFECT_SET_ATTACK_FINAL = 9
EFFECT_CHANGE_LEVEL = 10
EVENT_ADJUST = 100

local turn = 7
Duel = {
	GetTurnPlayer=function() return 0 end,
	GetTurnCount=function() return turn end,
	GetFieldGroupCount=function() return 0 end,
	IsPlayerAffectedByEffect=function() return nil end,
}

local target = {
	GetControler=function() return 1 end,
	GetBaseAttack=function() return 7000 end,
	GetOriginalLevel=function() return 8 end,
}
local attacker = {
	GetControler=function() return 0 end,
}
local source = {
	GetControler=function() return 0 end,
}

opcg = {
	ResolvePlayer=function(value, context)
		local you = context.player or 0
		return value == "OPPONENT" and (1 - you) or you
	end,
	GetLeader=function() return nil end,
	GetBaseCost=function(card) return card:GetOriginalLevel() end,
	GetBasePower=function(card) return card:GetBaseAttack() end,
	HasAttribute=function(card, attribute)
		return (card == attacker and attribute == "SLASH")
			or (card == target and attribute == "STRIKE")
	end,
	TraitContains=function(card, trait) return card == target and trait == "DRAGON" end,
	CompileFilter=function() return function() return true end end,
	GetAttachedDon=function() return 0 end,
}

local core = assert(dofile(root .. "/opcg_core.lua"))
local supported = core.GetSupportedOperations()
equal(count_keys(supported.conditions), 72, "all declared conditions supported")
equal(count_keys(supported.costs), 28, "all declared costs supported")
equal(supported.actions.ALLOW_UNLIMITED_DECK_COPIES, nil, "deck-copy rule remains external")
equal(supported.actions.DECK_BUILD_RESTRICTION, true, "deck restriction metadata is accepted")
equal(supported.actions.GAIN_EXTRA_TURN, nil, "extra turn remains external")

local context = {
	card=source,
	player=0,
	battle_attacker=attacker,
	event_target=target,
	event_targets={target},
	event_count=2,
	event_player=0,
	damage=6000,
}
equal(core.CheckCondition("BATTLE_ATTACKER_HAS_ATTRIBUTE",
	{op="BATTLE_ATTACKER_HAS_ATTRIBUTE", attribute="SLASH"}, context), true,
	"battle attacker attribute")
equal(core.CheckCondition("EVENT_CAUSED_BY_OWN_EFFECT",
	{op="EVENT_CAUSED_BY_OWN_EFFECT"}, context), true, "own effect provenance")
equal(core.CheckCondition("EVENT_COUNT_GTE",
	{op="EVENT_COUNT_GTE", count=2}, context), true, "event count")
equal(core.CheckCondition("EVENT_TARGET_BASE_COST_LTE",
	{op="EVENT_TARGET_BASE_COST_LTE", count=8}, context), true, "event cost lte")
equal(core.CheckCondition("EVENT_TARGET_BASE_COST_GTE_OR_EFFECT_PLAY",
	{op="EVENT_TARGET_BASE_COST_GTE_OR_EFFECT_PLAY", count=8}, context), true,
	"event cost gte")
equal(core.CheckCondition("EVENT_DAMAGE_OR_TARGET_BASE_POWER_GTE",
	{op="EVENT_DAMAGE_OR_TARGET_BASE_POWER_GTE", amount=6000}, context), true,
	"damage or power")
equal(core.CheckCondition("EVENT_TARGET_HAS_ATTRIBUTE",
	{op="EVENT_TARGET_HAS_ATTRIBUTE", attribute="STRIKE"}, context), true,
	"event target attribute")
equal(core.CheckCondition("EVENT_TARGET_TRAIT_CONTAINS",
	{op="EVENT_TARGET_TRAIT_CONTAINS", trait="DRAGON"}, context), true,
	"event target trait")

opcg._turn_state = {life_trigger_activated=true}
equal(core.CheckCondition("LIFE_TRIGGER_ACTIVATED",
	{op="LIFE_TRIGGER_ACTIVATED"}, context), true, "life trigger state")

opcg._battle_usage = setmetatable({}, {__mode="k"})
opcg._battle_usage[source] = {turn=turn, opponent_character=true}
equal(core.CheckCondition("SELF_BATTLED_OPPONENT_CHARACTER_THIS_TURN",
	{op="SELF_BATTLED_OPPONENT_CHARACTER_THIS_TURN"}, context), true,
	"battle usage state")

opcg._source_draw_usage = setmetatable({}, {__mode="k"})
context.effect = {effect_id="E1"}
equal(core.CheckCondition("SOURCE_EFFECT_DRAW_UNUSED_THIS_TURN",
	{op="SOURCE_EFFECT_DRAW_UNUSED_THIS_TURN"}, context), true,
	"source draw initially unused")
opcg._source_draw_usage[source] = {turn=turn, effect_id="E1"}
equal(core.CheckCondition("SOURCE_EFFECT_DRAW_UNUSED_THIS_TURN",
	{op="SOURCE_EFFECT_DRAW_UNUSED_THIS_TURN"}, context), false,
	"source draw usage recorded")

print(("opcg_contract_completion: %d assertions passed"):format(assertions))
