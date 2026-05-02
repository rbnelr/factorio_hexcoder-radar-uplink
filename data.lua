mod_name = "hexcoder_radar_uplink-"

data:extend({
	{
		type = "custom-input",
		name = mod_name.."open-gui",
		key_sequence = "",
		linked_game_control = "open-gui",
		include_selected_prototype = true,
	},
	{
		type = "sound",
		name = mod_name.."open-sound",
		filename = "__base__/sound/open-close/beacon-open.ogg" ,
		category = "gui-effect",
		volume = 0.25,
		speed = 1.06
	},
	{
		type = "sound",
		name = mod_name.."close-sound",
		filename = "__base__/sound/open-close/beacon-close.ogg",
		category = "gui-effect",
		volume = 0.25,
		speed = 1.04
	},
	{
		type = "sound",
		name = mod_name.."sel-switch-sound1",
		filename = "__core__/sound/list-box-click.ogg",
		category = "game-effect",
		volume = 0.8,
		speed = 0.9
	},
	{
		type = "sound",
		name = mod_name.."sel-switch-sound2",
		filename = "__core__/sound/smart-pipette.ogg",
		category = "game-effect",
		volume = 4.0,
		speed = 0.85
	},
	{
		type = "sprite",
		name = mod_name.."export_sprite",
		filename = "__hexcoder-radar-uplink__/graphics/export_white.png",
		size = 64,
		--tint = {0,0.9,0.6,1.0},
		--tint = {0.7,0.7,0.7,1.0},
		tint = {0.98,1,0.86,1.0},
		flags = {"gui-icon"}
	},
	{
		type = "sprite",
		name = mod_name.."import_sprite",
		filename = "__hexcoder-radar-uplink__/graphics/import_white.png",
		size = 64,
		--tint = {0,0.7,0.9,1.0},
		--tint = {0.7,0.7,0.7,1.0},
		tint = {0.36,0.51,0.56,1.0},
		flags = {"gui-icon"}
	},
	{
		type = "sprite",
		name = mod_name.."empty_sprite",
		filename = "__hexcoder-radar-uplink__/graphics/empty_64px.png",
		size = 64,
		flags = {"gui-icon"}
	},
	{
		type = "sprite",
		name = mod_name.."export_sprite48",
		filename = "__hexcoder-radar-uplink__/graphics/export_white_48px.png",
		size = 48,
		flags = {"gui-icon"}
	},
	{
		type = "sprite",
		name = mod_name.."receive_sprite",
		filename = "__hexcoder-radar-uplink__/graphics/receive.png",
		size = 32,
		mipmap_count = 2,
		flags = {"gui-icon"}
	},
})
