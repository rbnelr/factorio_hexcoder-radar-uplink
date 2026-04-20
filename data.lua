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
		volume = 1.0,
		speed = 0.9
	},
	{
		type = "sound",
		name = mod_name.."sel-switch-sound2",
		filename = "__core__/sound/smart-pipette.ogg",
		category = "game-effect",
		volume = 6.0,
		speed = 0.85
	}
})
