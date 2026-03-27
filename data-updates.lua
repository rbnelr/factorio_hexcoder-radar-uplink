mod_name = "hexcoder_radar_uplink-"
local dbg = true

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
	if not dbg then
		thing.picture = nil
		thing.sprites = nil
		thing.selection_box = {{0,0}, {0,0}}
		table.insert(thing.flags, "hide-alt-info")
	end
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
end

local cc = util.table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
cc.name = mod_name.."cc"
make_phantom(cc)

local dc = util.table.deepcopy(data.raw["decider-combinator"]["decider-combinator"])
dc.name = mod_name.."dc"
make_phantom(dc)

local ac = util.table.deepcopy(data.raw["arithmetic-combinator"]["arithmetic-combinator"])
ac.name = mod_name.."ac"
make_phantom(ac)

local pc = util.table.deepcopy(data.raw["proxy-container"]["proxy-container"])
pc.name = mod_name.."pc"
make_phantom(pc)

data:extend({cc, dc, ac, pc})

--[[
entity = table.deepcopy(data.raw["decider-combinator"]["decider-combinator"])
local REMOVE_KEY = "-remove-"
overwriteContent(entity, {
	name = "invisible-decider-combinator",
	order = "zzzz",
	selection_box = REMOVE_KEY,
	collision_box = REMOVE_KEY,
	collision_mask = { layers = { water_tile = true, item = true, is_object = true } },
	draw_circuit_wires = false,
	energy_source = {
		type = "void",
	},
	flags = {
		"placeable-neutral", 
		"player-creation",
		"not-on-map",
		"not-blueprintable",
		"hide-alt-info",
		"not-deconstructable",
		"not-upgradable"
	},
	sprites = noImage,
	equal_symbol_sprites = noImage,
	greater_or_equal_symbol_sprites = noImage,
	greater_symbol_sprites = noImage,
	less_or_equal_symbol_sprites = noImage,
	less_symbol_sprites = noImage,
	not_equal_symbol_sprites = noImage,
	activity_led_sprites = noImage,

}, REMOVE_KEY)

data:extend({	entity })
]]