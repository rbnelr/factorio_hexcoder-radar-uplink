data:extend({
	{
		type = "custom-input",
		name = "hexcoder_left_click",
		key_sequence = "mouse-button-1",
		hidden = true,
	},
	{
		type = "custom-input",
		name = "hexcoder_close_menu",
		key_sequence = "E",
		--consuming = "game-only",
		--linked_game_control = "close-menu",
		hidden = true,
	},
	{
		type = "custom-input",
		name = "hexcoder_close_escape",
		key_sequence = "Escape",
		--consuming = "game-only",
		--linked_game_control = "close-menu",
		hidden = true,
	},
	{
		type = "sound",
		name = "hexcoder-radar-open-sound",
		filename = "__base__/sound/open-close/beacon-open.ogg" ,
		volume = 0.23,
		speed = 1.06
	},
	{
		type = "sound",
		name = "hexcoder-radar-close-sound",
		filename = "__base__/sound/open-close/beacon-close.ogg",
		volume = 0.23,
		speed = 1.04
	}
})
