mod_name = "hexcoder_radar_uplink-"
local dbg = settings.startup["hexcoder_radar_uplink-debug"].value

local radar = data.raw["radar"]["radar"]
--table.insert(radar.flags, "get-by-unit-number")
-- override default auto-connect logic
-- would have updated wire_origin.radar connection manually, but can't change it from lua
-- so replicate this behavior manually via wire_origin.script
radar.connects_to_other_radars = false
data.raw["radar"]["radar"] = radar

local function make_phantom(thing)
	thing.flags = {"not-on-map",
		"not-rotatable", "not-flammable", "not-repairable",
		"not-deconstructable", "not-blueprintable", "no-copy-paste", "not-upgradable",
		"not-in-kill-statistics", "not-in-made-in",
		"not-selectable-in-game"
	}
	thing.hidden = true
	thing.minable = {minable=false, mining_time=999999}
	thing.corpse = nil
	thing.dying_explosion = nil
	thing.collision_box = nil
	thing.damaged_trigger_effect = nil
	thing.fast_replaceable_group = nil
	thing.open_sound = nil
	thing.close_sound = nil
	thing.activity_led_light = nil
	--thing.activity_led_light_offsets = nil
	thing.activity_led_sprites = nil
	thing.impact_category = nil
	
	if not dbg then
		table.insert(thing.flags, "hide-alt-info")
		
		thing.picture = nil
		thing.sprites = nil
		
		thing.selection_box = {{0,0}, {0,0}}
		thing.draw_circuit_wires = false
		
		thing.equal_symbol_sprites = nil
		thing.greater_or_equal_symbol_sprites = nil
		thing.greater_symbol_sprites = nil
		thing.less_or_equal_symbol_sprites = nil
		thing.less_symbol_sprites = nil
		thing.not_equal_symbol_sprites = nil
	end
end

local cc = util.table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
cc.name = mod_name.."cc"
make_phantom(cc)

local dc = util.table.deepcopy(data.raw["decider-combinator"]["decider-combinator"])
dc.name = mod_name.."dc"
dc.energy_source = { type = "void" }
make_phantom(dc)

local ac = util.table.deepcopy(data.raw["arithmetic-combinator"]["arithmetic-combinator"])
ac.name = mod_name.."ac"
ac.energy_source = { type = "void" }
make_phantom(ac)

local pc = util.table.deepcopy(data.raw["proxy-container"]["proxy-container"])
pc.name = mod_name.."pc"
make_phantom(pc)

data:extend({cc, dc, ac, pc})
