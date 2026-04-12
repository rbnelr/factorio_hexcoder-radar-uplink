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
		type = "int-setting",
		name = "hexcoder_radar_uplink-radar_poll_period",
		localised_name = "Polling interval for each radar (Performance)",
		localised_description = "Main logic is implemented using hidden circuits, but checking if radars have power requires polling.\nSet higher for better performance with high numbers of radars",
		setting_type = "runtime-global",
		default_value = 60, minimum_value = 1, maximum_value = 1800
	},
	{
		type = "bool-setting",
		name = "hexcoder_radar_uplink-debug",
		localised_name = "Debug Mode",
		localised_description = "Developer setting to visualize hidden combinators",
		setting_type = "startup",
		default_value = false
	}
})
