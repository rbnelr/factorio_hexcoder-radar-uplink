mod_name = "hexcoder_radar_uplink-"
local dbg = true

local radar = data.raw["radar"]["radar"]
--table.insert(radar.flags, "get-by-unit-number")
-- override default auto-connect logic
-- would have updated wire_origin.radar connection manually, but can't change it from lua
-- so replicate this behavior manually via wire_origin.script
radar.connects_to_other_radars = false
data.raw["radar"]["radar"] = radar

local cc = util.table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
cc.name = mod_name.."cc"
cc.flags = {"not-on-map",
"not-rotatable", "not-flammable", "not-repairable",
"not-deconstructable", "not-blueprintable", "no-copy-paste", "not-upgradable",
"not-in-kill-statistics", "not-in-made-in",
"not-selectable-in-game"
}
if not dbg then
	cc.sprites = nil
	cc.selection_box = {{0,0}, {0,0}}
	table.insert(cc.flags, "hide-alt-info")
end
cc.minable = {minable=false, mining_time=999999}
cc.corpse = nil
cc.dying_explosion = nil
cc.collision_box = nil
cc.damaged_trigger_effect = nil
cc.fast_replaceable_group = nil
cc.open_sound = nil
cc.close_sound = nil
cc.activity_led_light = nil
--cc.activity_led_light_offsets = nil
cc.activity_led_sprites = nil


local dc = util.table.deepcopy(data.raw["decider-combinator"]["decider-combinator"])
dc.name = mod_name.."dc"
dc.flags = {"not-on-map",
"not-rotatable", "not-flammable", "not-repairable",
"not-deconstructable", "not-blueprintable", "no-copy-paste", "not-upgradable",
"not-in-kill-statistics", "not-in-made-in",
"not-selectable-in-game"
}
if not dbg then
	dc.sprites = nil
	dc.selection_box = {{0,0}, {0,0}}
	table.insert(dc.flags, "hide-alt-info")
end
dc.minable = {minable=false, mining_time=999999}
dc.corpse = nil
dc.dying_explosion = nil
dc.collision_box = nil
dc.damaged_trigger_effect = nil
dc.fast_replaceable_group = nil
dc.open_sound = nil
dc.close_sound = nil
dc.activity_led_light = nil
--dc.activity_led_light_offsets = nil
dc.activity_led_sprites = nil

data:extend({cc, dc})


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