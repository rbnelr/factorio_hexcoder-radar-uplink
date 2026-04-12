
local myutil = require("script.myutil")
local radars = require("script.radars")

local M = {}

-- First attempt at adding migrations
function M.migrate_less0_1_4()
	local channels = util.table.deepcopy(storage.channels or {}) -- deepcopy just to be safe
	local old_radars = util.table.deepcopy(storage.radars or {})
	
	M._reset()
	
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
			data.S.mode = old_data.S.mode == "platforms" and "platforms" or "comms"
			if old_data.S.mode == "platforms" then
				data.S.read_mode = old_data.S.read_mode == "raw" and "raw" or "std"
				data.S.read = data.S.read or {}
				for k,def in pairs(radars.radar_defaults["pl_"..data.S.read_mode]) do
					data.S.read[k] = old_data.S.read and old_data.S.read[k] or def
				end
				data.S.selected_platform = nil
				if new_platforms[data.entity.force.index][old_data.S.selected_platform] then
					data.S.selected_platform = old_data.S.selected_platform
				end
			else
				data.S.selected_channel = 0
				if storage.channels.map[old_data.S.selected_channel] then
					data.S.selected_channel = old_data.S.selected_channel
				end
			end
			
			radars.refresh_radar(data)
		end
	end
end

commands.add_command("hexcoder_radar_uplink-reset", nil, function(command)
	M._reset()
end)

script.on_configuration_changed(function(data)
	local changes = data.mod_changes["hexcoder-radar-uplink"]
	if not changes then return end
	
	local old = changes.old_version
	if not old then
		M.init()
		return
	end
	
	if myutil.version_less(old, "0.1.4") then
		M.migrate_less0_1_4()
	end
end)

return M
