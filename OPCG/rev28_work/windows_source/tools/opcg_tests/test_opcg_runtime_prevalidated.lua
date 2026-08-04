local root = assert(arg[1], "runtime directory is required")

opcg = {}
local runtime = assert(dofile(root .. "/opcg_runtime.lua"))

local source_is_valid = true
local paid, executed = 0, 0
runtime.bind({
	check_condition=function() return source_is_valid end,
	can_pay_cost=function() return true end,
	pay_cost=function() paid = paid + 1 end,
	execute_action=function() executed = executed + 1; return true end,
})

local card = {}
runtime.register_card(card, {
	effects={{
		effect_id="COUNTER",
		timings={"COUNTER"},
		conditions={{op="SOURCE_STILL_IN_HAND"}},
		costs={{op="REST_DON"}},
		actions={{op="MODIFY_POWER"}},
		once_per_turn=false,
	}},
})

local ok = runtime.can_resolve(card, "COUNTER", {player=1})
assert(ok, "event counter must validate while in hand")
source_is_valid = false

local normal_ok = runtime.resolve(card, "COUNTER", {player=1})
assert(normal_ok == false, "normal resolve must re-check the moved source")

local prevalidated_ok = runtime.resolve_prevalidated(card, "COUNTER", {player=1})
assert(prevalidated_ok == true, "prevalidated event counter must resolve after trashing")
assert(paid == 1, "cost paid exactly once")
assert(executed == 1, "action executed exactly once")

print("opcg_runtime_prevalidated: 5 assertions passed")
