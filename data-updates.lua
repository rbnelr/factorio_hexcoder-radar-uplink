mod_name = "hexcoder_radar_circ_"
local dbg = false

local radar = data.raw["radar"]["radar"]
table.insert(radar.flags, "get-by-unit-number")
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

data:extend({cc})
