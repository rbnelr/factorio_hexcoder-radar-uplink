mod_name = "hexcoder_radar_circ_"

data:extend({
	{
		type = "custom-input",
		name = mod_name.."left-click",
		key_sequence = "mouse-button-1",
		hidden = true,
	},
	{
		type = "sound",
		name = mod_name.."open-sound",
		filename = "__base__/sound/open-close/beacon-open.ogg" ,
		volume = 0.23,
		speed = 1.06
	},
	{
		type = "sound",
		name = mod_name.."close-sound",
		filename = "__base__/sound/open-close/beacon-close.ogg",
		volume = 0.23,
		speed = 1.04
	}
})
