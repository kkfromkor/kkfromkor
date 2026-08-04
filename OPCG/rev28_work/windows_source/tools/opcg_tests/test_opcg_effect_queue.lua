local root = assert(arg[1], "runtime directory is required")

EVENT_CUSTOM = 0x10000000
EFFECT_TYPE_SINGLE = 0x1
EFFECT_TYPE_TRIGGER_F = 0x2
EFFECT_FLAG_DELAY = 0x4

local raised = {}
Duel = {
	GetTurnPlayer=function() return 0 end,
	GetCurrentChain=function() return 0 end,
	RaiseSingleEvent=function(_, _, resolver, _, _, _, serial)
		raised[#raised + 1] = {resolver=resolver, serial=serial}
	end,
}
Effect = {
	CreateEffect=function(handler)
		local value = {handler=handler}
		function value:GetHandler() return self.handler end
		function value:SetType(item) self.type = item end
		function value:SetCode(item) self.code = item end
		function value:SetProperty(item) self.property = item end
		function value:SetDescription(item) self.description = item end
		function value:SetCondition(item) self.condition = item end
		function value:SetTarget(item) self.target = item end
		function value:SetOperation(item) self.operation = item end
		function value:SetRange(item) self.range = item end
		function value:SetTargetRange(left, right)
			self.target_range = {left, right}
		end
		return value
	end,
}

opcg = {}
assert(dofile(root .. "/opcg_effect_queue.lua"))
local queue = opcg.effect_queue

local function card(player)
	local value = {registered={}}
	function value:GetControler() return player end
	function value:RegisterEffect(effect)
		self.registered[#self.registered + 1] = effect
	end
	return value
end
local function effect(id, extra)
	local value = {effect_id=id, costs={}, source_text=""}
	for key, item in pairs(extra or {}) do value[key] = item end
	return value
end
local function assert_equal(actual, expected, label)
	if actual ~= expected then
		error(("%s: expected %s, got %s"):format(label, tostring(expected), tostring(actual)))
	end
end

queue.reset()
local tp = card(0)
local ntp = card(1)
local ra, rb, rx, rc = {}, {}, {}, {}
local a = queue.enqueue(tp, effect("A"), ra, {player=0})
local b = queue.enqueue(tp, effect("B"), rb, {player=0})
local x = queue.enqueue(ntp, effect("X"), rx, {player=1})

queue.flush()
assert_equal(#raised, 1, "only one TP effect is raised at a time")
assert_equal(raised[1].serial, a.serial, "first TP item")
assert_equal(queue.flush(), false, "inflight effect blocks another raise")
assert_equal(#raised, 1, "repeated flush cannot build a reverse chain")

local active_a = assert(queue.take(a.serial, ra))
queue._active_item = active_a
local c = queue.enqueue(tp, effect("C"), rc, {player=0})
queue._active_item = nil
assert_equal(c.generation, 1, "effect created during A is deferred")

raised = {}
queue.after_chain()
assert_equal(#raised, 1, "remaining TP generation-0 bucket")
assert_equal(raised[1].serial, b.serial, "B resolves before the opponent")
assert(queue.take(b.serial, rb))

raised = {}
queue.after_chain()
assert_equal(#raised, 1, "non-turn generation-0 bucket")
assert_equal(raised[1].serial, x.serial, "opponent pending effect before new TP effect")
assert(queue.take(x.serial, rx))

raised = {}
queue.after_chain()
assert_equal(#raised, 1, "deferred TP generation-1 bucket")
assert_equal(raised[1].serial, c.serial, "C resolves after the opponent")
assert(queue.take(c.serial, rc))

raised = {}
queue.after_chain()
assert_equal(queue.pending_count(), 0, "queue drained")
assert_equal(#raised, 0, "no phantom events")

assert_equal(queue.is_optional(effect("forced")), false, "forced effect")
assert_equal(queue.is_optional(effect("cost", {costs={{op="REST_DON"}}})), true, "cost may be declined")
assert_equal(queue.is_optional(effect("explicit", {optional=true})), true, "explicit optional")
assert_equal(queue.is_optional(effect("mandatory", {mandatory=true})), false, "explicit mandatory")

queue.reset()
local direct_log = {}
local direct_a, direct_b, direct_x, direct_c = card(0), card(0), card(1), card(0)
direct_a.definition = {effects={effect("A", {timings={"WHEN"}})}}
direct_b.definition = {effects={effect("B", {timings={"WHEN"}})}}
direct_x.definition = {effects={effect("X", {timings={"WHEN"}})}}
direct_c.definition = {effects={effect("C", {timings={"WHEN"}})}}
opcg.runtime = {
	get_definition=function(value) return value.definition end,
	can_resolve=function() return true end,
	resolve=function(_, effect_id)
		direct_log[#direct_log + 1] = effect_id
		if effect_id == "A" then
			queue.resolve_timing({direct_c}, "WHEN", {})
		end
		return true
	end,
	resolve_prevalidated=function(_, effect_id)
		direct_log[#direct_log + 1] = "PRE:" .. effect_id
		return true
	end,
}

local _, resolved = queue.resolve_timing(
	{direct_a, direct_b, direct_x}, "WHEN", {})
assert_equal(#direct_log, 4, "direct timing resolution count")
assert_equal(direct_log[1], "A", "direct TP first")
assert_equal(direct_log[2], "B", "same-generation TP second")
assert_equal(direct_log[3], "X", "same-generation non-turn player")
assert_equal(direct_log[4], "C", "new generation after prior generation")
assert_equal(#resolved, 4, "direct result records")
assert_equal(queue.direct_pending_count(), 0, "direct queue drained")
assert_equal(queue.has_timing(direct_a, "WHEN", {}), true, "timing lookup true")
assert_equal(queue.has_timing(direct_a, "OTHER", {}), false, "timing lookup false")

queue.reset()
raised = {}
local semantic_log = {}
local semantic = card(0)
local semantic_effect = effect("S", {timings={"ON_PLAY"}})
semantic.definition = {effects={semantic_effect}}
queue.register_semantic(semantic, semantic_effect, "ON_PLAY")
opcg.runtime.resolve = function(_, effect_id)
	semantic_log[#semantic_log + 1] = effect_id
	return true
end
local semantic_enqueued, semantic_resolved = queue.resolve_timing(
	{semantic}, "ON_PLAY", {}, {engine=true})
assert_equal(#semantic_enqueued, 1, "semantic timing enqueued")
assert_equal(#semantic_resolved, 0, "semantic timing defers to engine")
assert_equal(#raised, 1, "semantic timing raises engine event")
assert_equal(raised[1].resolver, semantic.registered[1], "registered resolver raised")
assert_equal(#semantic_log, 0, "semantic timing is not direct resolved")
assert(queue.take(semantic_enqueued[1].serial, raised[1].resolver))

queue.reset()
local event = card(1)
event.definition = {effects={effect("E", {timings={"COUNTER"}})}}
local activation_hook_called = false
local _, event_resolved = queue.resolve_timing({event}, "COUNTER", {}, {
	prevalidated=true,
	before_resolve=function()
		activation_hook_called = true
		return true
	end,
})
assert_equal(activation_hook_called, true, "activation hook runs before resolution")
assert_equal(direct_log[#direct_log], "PRE:E", "prevalidated resolver used")
assert_equal(event_resolved[1].ok, true, "prevalidated timing resolved")

-- 총합룰 8-6-2-1: a [Trigger] interrupts an effect-damage drain and resolves
-- on the spot; what it spawns waits for the damage processing to end (8-6-2).
queue.reset()
local interrupt_log = {}
local damage_source, trigger_card, spawned = card(0), card(1), card(1)
damage_source.definition = {effects={effect("DMG", {timings={"WHEN"}})}}
trigger_card.definition = {effects={effect("TRIG", {timings={"LIFE_TRIGGER"}})}}
spawned.definition = {effects={effect("SPAWN", {timings={"AFTER"}})}}
opcg.runtime.resolve = function(_, effect_id)
	interrupt_log[#interrupt_log + 1] = effect_id
	if effect_id == "DMG" then
		local _, inline = queue.resolve_timing({trigger_card}, "LIFE_TRIGGER", {},
			{immediate=true})
		assert_equal(#inline, 1, "trigger resolves inline inside the drain")
		interrupt_log[#interrupt_log + 1] = "DMG_END"
	elseif effect_id == "TRIG" then
		queue.resolve_timing({spawned}, "AFTER", {})
	end
	return true
end
queue.resolve_timing({damage_source}, "WHEN", {})
assert_equal(table.concat(interrupt_log, ","), "DMG,TRIG,DMG_END,SPAWN",
	"trigger interrupts, its spawns wait for the processing to end")

-- 총합룰 8-6-1: the turn player's whole block resolves before the opponent's;
-- within one player the deterministic stand-in order is leader-first.
queue.reset()
opcg.IsLeader = function(value) return value.is_leader == true end
local order_log = {}
opcg.runtime.resolve = function(_, effect_id)
	order_log[#order_log + 1] = effect_id
	return true
end
local char_tp, leader_tp, char_ntp, leader_ntp = card(0), card(0), card(1), card(1)
leader_tp.is_leader = true
leader_ntp.is_leader = true
char_tp.definition = {effects={effect("TC", {timings={"T"}})}}
leader_tp.definition = {effects={effect("TL", {timings={"T"}})}}
char_ntp.definition = {effects={effect("NC", {timings={"T"}})}}
leader_ntp.definition = {effects={effect("NL", {timings={"T"}})}}
queue.resolve_timing({char_tp, char_ntp, leader_tp, leader_ntp}, "T", {})
assert_equal(table.concat(order_log, ","), "TL,TC,NL,NC",
	"turn player block first, leader before character within each player")

-- engine path mirrors the same leader preference inside a bucket
queue.reset()
raised = {}
local engine_char, engine_leader = card(0), card(0)
engine_leader.is_leader = true
local engine_char_resolver, engine_leader_resolver = {}, {}
local engine_char_item = queue.enqueue(engine_char, effect("EC"), engine_char_resolver, {player=0})
local engine_leader_item = queue.enqueue(engine_leader, effect("EL"), engine_leader_resolver, {player=0})
queue.flush()
assert_equal(raised[1].serial, engine_leader_item.serial, "engine flush raises the leader item first")
assert(queue.take(engine_leader_item.serial, engine_leader_resolver))
assert(queue.take(engine_char_item.serial, engine_char_resolver))
opcg.IsLeader = nil

print("opcg_effect_queue: native and direct queue assertions passed")
