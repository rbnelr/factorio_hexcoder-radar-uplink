data:extend({
	{
		type = "bool-setting",
		name = "hexcoder_radar_uplink-allow_interplanetary_comms",
		localised_name = "Allow interplanetary comms",
		localised_description = "Allow interplanetary signal sharing and reading of platform details even when not currently orbiting planet radar is on",
		setting_type = "runtime-global",
		default_value = true
	},
	{
		type = "bool-setting",
		name = "hexcoder_radar_uplink-debug",
		localised_name = "Debug Mode",
		localised_description = "Visualize hidden wires etc.\nHidden things appear for newly configured radars or platforms only. Use full reset (/hexcoder_radar_uplink-reset)",
		setting_type = "startup",
		default_value = false
	}
})
