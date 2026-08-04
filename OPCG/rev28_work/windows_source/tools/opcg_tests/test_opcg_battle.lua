local root = assert(arg[1], "runtime directory is required")

opcg = {}
local battle = assert(dofile(root .. "/opcg_battle.lua"))

local assertions = 0
local function equal(actual, expected, label)
	assertions = assertions + 1
	if actual ~= expected then
		error(("%s: expected %s, got %s"):format(label, tostring(expected), tostring(actual)))
	end
end

local function make_card(values)
	values = values or {}
	values.active = values.active ~= false
	values.onfield = values.onfield ~= false
	values.keywords = values.keywords or {}
	values.GetTurnID = values.GetTurnID or function() return values.turn_id or 0 end
	return values
end

local attacker = make_card{
	name="attacker", controller=0, character=true, power=7000, id=10,
}
local leader = make_card{
	name="leader", controller=1, leader=true, power=5000, id=20,
}
local blocker = make_card{
	name="blocker", controller=1, character=true, power=5000, id=21,
	keywords={BLOCKER=true},
}
local counter = make_card{
	name="counter", controller=1, onfield=false, counter=2000, in_hand=true, id=30,
}

local timing_log, attack_lines, damage_calls = {}, {}, {}
local counter_selected = false
local player_turns = {[0]=2, [1]=2}
local fields = {[0]={attacker}, [1]={leader, blocker}}
local hands = {[0]={}, [1]={counter}}

local bridge = {
	turn_player=function() return 0 end,
	personal_turn_count=function(player) return player_turns[player] end,
	global_turn_count=function() return 5 end,
	controller=function(card) return card.controller end,
	field_id=function(card) return card.id end,
	is_active=function(card) return card.active end,
	is_on_field=function(card) return card.onfield end,
	is_leader=function(card) return card.leader == true end,
	is_character=function(card) return card.character == true end,
	is_event=function(card) return card.event == true end,
	has_timing=function(card, timing) return card.event == true and timing == "COUNTER" end,
	has_keyword=function(card, keyword) return card.keywords[keyword] == true end,
	set_rested=function(card) card.active = false end,
	power=function(card) return card.power end,
	counter=function(card) return card.counter or 0 end,
	field_cards=function(player)
		local result = {}
		for _, card in ipairs(fields[player]) do
			if card.onfield then result[#result + 1] = card end
		end
		return result
	end,
	hand_cards=function(player)
		local result = {}
		for _, card in ipairs(hands[player]) do
			if card.in_hand then result[#result + 1] = card end
		end
		return result
	end,
	emit_attack=function(_, target)
		attack_lines[#attack_lines + 1] = target.name
	end,
	dispatch=function(_, timing) timing_log[#timing_log + 1] = timing end,
	select_blocker=function(_, candidates) return candidates[1] end,
	select_counter=function(_, candidates)
		if counter_selected then return nil end
		counter_selected = true
		return candidates[1]
	end,
	resolve_event_counter=function(card, state)
		card.in_hand = false
		state.target.power = state.target.power + 3000
		return {card}, {{accepted=true, ok=true}}
	end,
	trash_counter=function(card) card.in_hand = false end,
	ko=function(card) card.onfield = false end,
	damage_leader=function(player, amount, context)
		damage_calls[#damage_calls + 1] = {
			player=player, amount=amount, banish=context.banish,
		}
		return {defeated=false, processed=amount}
	end,
	advance_boundary=function() end,
}

local ok, state = battle.resolve_attack(attacker, leader, {bridge=bridge})
equal(ok, true, "battle resolves")
equal(state.blocker, blocker, "blocker redirects target")
equal(blocker.active, false, "blocker rests")
equal(state.counter_power, 2000, "counter power added")
equal(counter.in_hand, false, "counter card trashed")
equal(state.outcome, "CHARACTER_KO", "equal power KOs character")
equal(blocker.onfield, false, "blocker moved by KO bridge")
equal(attack_lines[1], "leader", "initial attack line")
equal(attack_lines[2], "blocker", "redirected attack line")
equal(timing_log[1], "WHEN_ATTACKING", "when-attacking first")
equal(timing_log[2], "WHEN_ATTACKING_OPPONENT_LEADER", "leader-attack timing second")
equal(timing_log[3], "ON_OPPONENT_ATTACK", "opponent-attack third")
equal(timing_log[4], "ON_BLOCK", "on-block after redirect")
equal(timing_log[5], "ON_OPPONENT_BLOCKER_ACTIVATED", "blocker reaction timing")
equal(timing_log[6], "ON_OPPONENT_BLOCKER_OR_EVENT_ACTIVATED", "combined blocker timing")

attacker = make_card{
	name="double", controller=0, character=true, power=9000, id=40,
	keywords={DOUBLE_ATTACK=true, BANISH=true},
}
leader = make_card{
	name="leader2", controller=1, leader=true, power=5000, id=41,
}
fields = {[0]={attacker}, [1]={leader}}
hands = {[0]={}, [1]={}}
counter_selected = true
local ok2, state2 = battle.resolve_attack(attacker, leader, {bridge=bridge})
equal(ok2, true, "leader battle resolves")
equal(state2.outcome, "LEADER_DAMAGE", "leader damage outcome")
equal(damage_calls[1].amount, 2, "double attack deals two")
equal(damage_calls[1].banish, true, "banish forwarded to life processor")

attacker = make_card{
	name="small", controller=0, character=true, power=3000, id=50,
}
leader = make_card{
	name="large", controller=1, leader=true, power=5000, id=51,
}
fields = {[0]={attacker}, [1]={leader}}
local ok3, state3 = battle.resolve_attack(attacker, leader, {bridge=bridge})
equal(ok3, true, "losing attack still resolves")
equal(state3.outcome, "ATTACK_LOST", "lower power does nothing")

attacker = make_card{
	name="event-counter-attacker", controller=0, character=true, power=6000, id=55,
}
leader = make_card{
	name="event-counter-leader", controller=1, leader=true, power=5000, id=56,
}
local event_counter = make_card{
	name="event-counter", controller=1, event=true, onfield=false,
	counter=0, in_hand=true, id=57,
}
fields = {[0]={attacker}, [1]={leader}}
hands = {[0]={}, [1]={event_counter}}
counter_selected = false
local ok4, state4 = battle.resolve_attack(attacker, leader, {bridge=bridge})
equal(ok4, true, "event-counter battle resolves")
equal(event_counter.in_hand, false, "event counter leaves hand at activation")
equal(state4.counter_cards[1].kind, "EVENT", "event counter recorded")
equal(state4.target_power, 8000, "event counter effect modifies battle power")
equal(state4.outcome, "ATTACK_LOST", "event counter can defend attack")

player_turns[0] = 1
attacker.active = true
local can_first, reason_first = battle.can_declare(attacker, {bridge=bridge})
equal(can_first, false, "first personal turn cannot attack")
equal(reason_first, "FIRST_PERSONAL_TURN", "first turn rejection reason")

player_turns[0] = 2
local active_character = make_card{
	controller=1, character=true, active=true, id=60,
}
equal(battle.is_legal_target(active_character, 0, attacker, {bridge=bridge}),
	false, "active character is not a normal attack target")

print(("opcg_battle: %d assertions passed"):format(assertions))
