
-- is this correct if multiple mods attempt this?
table.insert(data.raw["radar"]["radar"].flags, "get-by-unit-number")

local dbg = true

local radar = data.raw["radar"]["radar"]
local cc = util.table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])

-- Radar uses connects_to_other_radars to auto-send circuit signals to other radars by adding a hidden wire
-- Could disable this so I can cleanly output to wire without accidentally sending our data to other radars
-- But apparently there is no way of directly writing signals via lua, so we still need the constant combinator

local conn = radar.circuit_connector.points

cc.name = "hexcoder-radar-gui-cc"
cc.flags = {"not-on-map", "hide-alt-info",
"not-rotatable", "not-flammable", "not-repairable",
"not-deconstructable", "not-blueprintable", "no-copy-paste", "not-upgradable",
"not-in-kill-statistics", "not-in-made-in",
"not-selectable-in-game"
}
cc.minable = {minable=false, mining_time=999999}
-- make cc look like circuit connector on radar would, as once I disconnect radar, then connect to cc instead, radar connector is no drawn
cc.sprites = { layers = {
	radar.circuit_connector.sprites.connector_main,
	--radar.circuit_connector.sprites.connector_shadow,
	--radar.circuit_connector.sprites.wire_pins,
	--radar.circuit_connector.sprites.wire_pins_shadow,
}}
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

-- match radar circuit connection points if placed at same position
if not dbg then
	cc.selection_box = {{0,0}, {0,0}}
else
	cc.selection_box = {{-2.5,-0.5}, {-1.5,0.5}}
end
cc.circuit_wire_connection_points = { conn, conn, conn, conn }

data:extend({cc})

--[[wa
    collision_box = {{-1.2, -1.2}, {1.2, 1.2}},
    selection_box = {{-1.5, -1.5}, {1.5, 1.5}},

generate_constant_combinator
  {
    type = "constant-combinator",
    name = "constant-combinator",
    icon = "__base__/graphics/icons/constant-combinator.png",
    flags = {"placeable-neutral"},
    minable = {mining_time = 0.1, result = "constant-combinator"},
    max_health = 120,
    corpse = "constant-combinator-remnants",
    dying_explosion = "constant-combinator-explosion",
    icon_draw_specification = {scale = 0.7},
  },
--]]