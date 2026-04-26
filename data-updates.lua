local meld = require("__core__.lualib.meld")

mod_name = "hexcoder_radar_uplink-"
local dbg = settings.startup["hexcoder_radar_uplink-debug"].value

meld(data.raw["radar"]["radar"], {
	-- override default auto-connect logic
	-- would have updated wire_origin.radar connection manually, but can't change it from lua
	-- so replicate this behavior manually via wire_origin.script
	connects_to_other_radars = false
})

local function make_phantom(source, new_name)
	local thing = util.table.deepcopy(source)
	
	thing.name = new_name
	
	thing.flags = {"not-on-map",
		"not-rotatable", "not-flammable", "not-repairable",
		"not-deconstructable", "not-blueprintable", "no-copy-paste", "not-upgradable",
		"not-in-kill-statistics", "not-in-made-in",
		--"not-selectable-in-game",
		"no-automated-item-removal", "no-automated-item-insertion"
	}
	
	thing.hidden = true
	thing.minable = {minable=false, mining_time=999999}
	thing.corpse = nil
	thing.dying_explosion = nil
	thing.collision_box = nil
	thing.collision_mask = { layers = {} }
	thing.damaged_trigger_effect = nil
	thing.fast_replaceable_group = nil
	thing.open_sound = nil
	thing.close_sound = nil
	thing.impact_category = nil
	thing.working_sound = nil
	
	if thing.energy_source then
		thing.energy_source = { type = "void" }
	end
	
	if dbg then
		--sets the variable, but does not actually render higher, likely hardcoded for combinators etc.
		--thing.integration_patch_render_layer = "elevated-object" -- would be nice to render this on top of cargo hatches of hub
		thing.selection_priority = 100 -- selectable on top of platform hub for debugging
	else
		table.insert(thing.flags, "hide-alt-info")
		
		thing.picture = nil
		thing.sprites = nil
		
		thing.selection_box = {{0,0}, {0,0}}
		thing.selectable_in_game = false
		
		thing.draw_circuit_wires = false
		
		-- CC
		thing.activity_led_light = nil
		thing.activity_led_sprites = nil
		--thing.activity_led_light_offsets = nil
		-- DC
		thing.equal_symbol_sprites = nil
		thing.greater_symbol_sprites = nil
		thing.less_symbol_sprites = nil
		thing.greater_or_equal_symbol_sprites = nil
		thing.less_or_equal_symbol_sprites = nil
		thing.not_equal_symbol_sprites = nil
		-- AC
		thing.plus_symbol_sprites = nil
		thing.minus_symbol_sprites = nil
		thing.multiply_symbol_sprites = nil
		thing.divide_symbol_sprites = nil
		thing.modulo_symbol_sprites = nil
		thing.power_symbol_sprites = nil
		thing.left_shift_symbol_sprites = nil
		thing.right_shift_symbol_sprites = nil
		thing.and_symbol_sprites = nil
		thing.or_symbol_sprites = nil
		thing.xor_symbol_sprites = nil
	end
	
	return thing
end

local cc = make_phantom(data.raw["constant-combinator"]["constant-combinator"], mod_name.."cc")
local dc = make_phantom(data.raw["decider-combinator"]["decider-combinator"], mod_name.."dc")
local ac = make_phantom(data.raw["arithmetic-combinator"]["arithmetic-combinator"], mod_name.."ac")
local pc = make_phantom(data.raw["proxy-container"]["proxy-container"], mod_name.."pc")

data:extend({cc, dc, ac, pc})

--[[
local pulsegen_cc = util.table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
pulsegen_cc.name = mod_name.."pulsegen_cc"
-- this is used by pushbutton (and was added to the API for it!?)
-- unfortunately is does not actually work for scripts to generated pulses via LuaConstantCombinatorControlBehavior.enabled = true
pulsegen_cc.pulse_duration = 1
make_phantom(pulsegen_cc)

data:extend({pulsegen_cc})
]]

--[[ -- CC-like thing on the radar that can serve as a second circuit connection for dynamic selection
local function make_sel_module(thing)
	thing.flags = {"not-on-map",
		"not-rotatable", "not-flammable", "not-repairable",
		"not-deconstructable", "not-blueprintable", "no-copy-paste", "not-upgradable",
		"not-in-kill-statistics", "not-in-made-in",
		"no-automated-item-removal", "no-automated-item-insertion"
	}
	
	thing.hidden = true
	thing.minable = {minable=false, mining_time=999999}
	thing.corpse = nil
	thing.dying_explosion = nil
	thing.collision_box = nil
	thing.collision_mask = { layers = {} }
	thing.damaged_trigger_effect = nil
	thing.fast_replaceable_group = nil
	thing.open_sound = nil
	thing.close_sound = nil
	thing.impact_category = nil
	thing.snap_to_grid = false
	
	thing.render_layer = "higher-object-under"
	thing.integration_patch_render_layer = "higher-object-under"
	thing.secondary_draw_order = 255
	thing.selection_priority = 100
end

local sel_module = util.table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
sel_module.name = mod_name.."sel_module"
make_sel_module(sel_module)

data:extend({sel_module})
]]
