local radars = require("script.radars")

local M = {}

--[[ Migration Notes:

	-Be careful about default settings, user-customized radars should use existing settings, not defaults
	
]]

-- First attempt at adding migrations
function M.migrate_less0_1_4()
	local channels = util.table.deepcopy(storage.channels or {}) -- deepcopy just to be safe
	local old_radars = util.table.deepcopy(storage.radars or {})
	
	M.reset()
	
	local new_platforms = {}
	for _,force in pairs(game.forces) do
		new_platforms[force.index] = {}
		for id,plat in pairs(force.platforms) do
			new_platforms[force.index][id] = plat
		end
	end
	
	storage.channels.next_id = channels.next_id or 1
	for id,ch in pairs(channels.map) do
		if type(id) == "number" and id > 1 and ch and ch.name and id < storage.channels.next_id then
			storage.channels.map[id] = { id=id, name=ch.name, is_interplanetary=ch.is_interplanetary or false }
		end
	end
	for id,data in pairs(storage.radars) do
		local old_data = old_radars[id]
		if old_data and old_data.entity and old_data.entity.valid and old_data.entity.unit_number and old_data.S then
			local S = {}
			S.mode = old_data.S.mode == "platforms" and "platforms" or "comms"
			
			S.sel_orbit_only = old_data.S.sel_orbit_only
			S.dyn = old_data.S.dyn
			S.dyn_text = old_data.S.dyn_text
			
			if old_data.S.mode == "platforms" then
				S.read_mode = old_data.S.read_mode == "raw" and "raw" or "std"
				S.read = {}
				for k,_ in pairs(radars.radar_defaults[S.read_mode]) do ---@diagnostic disable-line
					S.read[k] = old_data.S.read and old_data.S.read[k] or { false, false } -- copy setting or false to avoid affecting existing circuits
				end
				
				S.selected_platform = nil
				
				local sel = old_data.S.selected_platform
				if sel and sel.object_name == "LuaSpacePlatform" then
					S.selected_platform = sel
				elseif type(sel) == "number" then
					S.selected_platform = new_platforms[data.entity.force.index][sel]
				end
			else
				S.selected_channel = 0
				if storage.channels.map[old_data.S.selected_channel] then
					S.selected_channel = old_data.S.selected_channel
				end
			end
			
			data.S = S
			radars.refresh_radar(data)
		end
	end
end

commands.add_command("hexcoder_radar_uplink-migrate", nil, function(command)
	M.migrate_less0_1_4()
end)

script.on_configuration_changed(function(data)
	local changes = data.mod_changes["hexcoder-radar-uplink"]
	if not changes then return end
	
	local old = changes.old_version
	if not old then
		M.init()
		return
	end
	
	if helpers.compare_versions(old, "0.1.4") < 0 then
		M.migrate_less0_1_4()
	end
end)

return M
