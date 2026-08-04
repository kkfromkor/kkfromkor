local root = assert(arg[1], "runtime directory is required")

LOCATION_EXTRA = 0x40
LOCATION_REMOVED = 0x20
POS_FACEUP = 0x5
REASON_BATTLE = 0x20

opcg = {}
local life = assert(dofile(root .. "/opcg_life.lua"))

local assertions = 0
local function equal(actual, expected, label)
	assertions = assertions + 1
	if actual ~= expected then
		error(("%s: expected %s, got %s"):format(label, tostring(expected), tostring(actual)))
	end
end

local function make_card(name, sequence, trigger)
	return {
		name=name,
		sequence=sequence,
		trigger=trigger == true,
		location="LIFE",
	}
end

local cards = {
	make_card("bottom", 0, false),
	make_card("trigger", 1, true),
	make_card("top", 2, false),
}
local confirmed, dispatched, wins = {}, {}, {}
local activate_trigger = false

local bridge = {
	life_cards=function()
		local result = {}
		for _, card in ipairs(cards) do
			if card.location == "LIFE" then result[#result + 1] = card end
		end
		return result
	end,
	sequence=function(card) return card.sequence end,
	has_trigger=function(card) return card.trigger end,
	can_add_to_hand=function() return true end,
	confirm_private=function(player, card)
		confirmed[#confirmed + 1] = {player=player, card=card}
	end,
	choose_trigger=function() return activate_trigger end,
	to_hand=function(_, card) card.location = "HAND" end,
	to_trash=function(card) card.location = "TRASH" end,
	to_limbo=function(_, card) card.location = "LIMBO" end,
	is_in_limbo=function(card) return card.location == "LIMBO" end,
	dispatch_trigger=function(card, context)
		dispatched[#dispatched + 1] = {card=card, context=context}
	end,
	win=function(player, reason) wins[#wins + 1] = {player=player, reason=reason} end,
}

equal(life.top(0, {bridge=bridge}).name, "top", "highest sequence is life top")

local first = life.damage_leader(0, 1, {bridge=bridge})
equal(first.processed, 1, "one damage processed")
equal(cards[3].location, "HAND", "non-trigger life goes to hand")
equal(confirmed[1].player, 0, "life is privately confirmed to owner")

activate_trigger = true
local second = life.damage_leader(0, 1, {bridge=bridge})
equal(second.cards[1].triggered, true, "trigger accepted")
equal(dispatched[1].card.name, "trigger", "trigger timing dispatched")
equal(cards[2].location, "TRASH", "trigger card trashes after resolving in limbo")

local confirms_before_banish = #confirmed
local third = life.damage_leader(0, 1, {bridge=bridge, banish=true})
equal(third.cards[1].banished, true, "banish marked")
equal(cards[1].location, "TRASH", "banished life goes to trash")
equal(#confirmed, confirms_before_banish, "banish does not offer trigger")

local defeated = life.damage_leader(0, 1, {bridge=bridge})
equal(defeated.defeated, true, "zero-life damage defeats")
equal(wins[1].player, 1, "opponent wins zero-life damage")

local high = make_card("high", 1, false)
local low = make_card("low", 0, false)
cards = {low, high}
activate_trigger = false
local double = life.damage_leader(1, 2, {bridge=bridge})
equal(double.processed, 2, "double damage processes twice")
equal(double.cards[1].card.name, "high", "double damage first takes top")
equal(double.cards[2].card.name, "low", "double damage then takes next")

-- a face-up life card is public: taking it as damage must not privately
-- re-confirm it, while its [Trigger] window stays available
local shown = make_card("shown", 1, true)
shown.faceup = true
local hidden = make_card("hidden", 0, false)
cards = {hidden, shown}
local aware = {}
for key, value in pairs(bridge) do aware[key] = value end
aware.is_facedown = function(card) return card.faceup ~= true end
activate_trigger = false
local confirms_before = #confirmed
local faceup_hit = life.damage_leader(0, 1, {bridge=aware})
equal(faceup_hit.processed, 1, "face-up damage processed")
equal(shown.location, "HAND", "face-up life goes to hand")
equal(#confirmed, confirms_before, "face-up life is not privately confirmed")
equal(faceup_hit.cards[1].has_trigger, true, "face-up life still offers its trigger")
life.damage_leader(0, 1, {bridge=aware})
equal(#confirmed, confirms_before + 1, "face-down life is still privately confirmed")

print(("opcg_life: %d assertions passed"):format(assertions))
