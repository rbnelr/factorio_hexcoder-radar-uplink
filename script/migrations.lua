local radars = require("script.radars")

local M = {}

--[[ Migration Notes:

	-Be careful about default settings, user-customized radars should use existing settings, not defaults
	
]]

-- First attempt at adding migrations
function M.migrate_less0_1_4()
	---@class oldRadarData
	---@field S oldRadarSettings
	
	---@class oldRadarSettings
	---@field mode "comms"|"platforms"
	---@field sel_orbit_only? boolean
	---@field selected_channel? channel_id
	---@field selected_platform? PlatformData|LuaSpacePlatform|platform_index
	---@field dyn? CircRG|"circuit_red"|"circuit_green"
	---@field dyn_text? string
	---@field read_mode? "std"|"raw"
	---@field read? ReadStd|ReadRaw

	local channels = util.table.deepcopy(storage.channels or {}) -- deepcopy just to be safe
	local old_radars = util.table.deepcopy(storage.radars or {}) --[[@as table<unit_number, oldRadarData>]]
	
	M.reset()
	
	storage.channels.next_id = channels.next_id or 1
	for id,ch in pairs(channels.map) do
		if type(id) == "number" and id > 1 and ch and ch.name and id < storage.channels.next_id then
			storage.channels.map[id] = { id=id, name=ch.name, is_interplanetary=ch.is_interplanetary or false }
		end
	end
	for id,data in pairs(storage.radars) do
		local old_data = old_radars[id]
		if old_data and old_data.S then
			local S = {}
			S.mode = old_data.S.mode == "platforms" and "platforms" or "comms"
			
			S.sel_orbit_only = old_data.S.sel_orbit_only
			
			local dyn = old_data.S.dyn
			if type(dyn) == "string" then
				S.dyn = dyn
			elseif type(dyn) == "table" then
				S.dyn = dyn.R and "circuit_red" or dyn.G and "circuit_green" or nil
			end
			
			S.dyn_text = old_data.S.dyn_text
			
			if old_data.S.mode == "platforms" then
				S.read_mode = old_data.S.read_mode or "std"
				S.read = {}
				for k,_ in pairs(radars.defaults[S.read_mode]) do ---@diagnostic disable-line
					S.read[k] = old_data.S.read and old_data.S.read[k] or { false, false } -- copy setting or false to avoid affecting existing circuits
				end
				
				S.selected_platform = nil
				
				local sel = old_data.S.selected_platform
				if sel and sel.object_name == "table" then
					S.selected_platform = sel
				--elseif sel and sel.object_name == "LuaSpacePlatform" then -- only in dev: was never released
				--	S.selected_platform = storage.platforms:init_platform(sel)
				elseif type(sel) == "number" then
					S.selected_platform = storage.platforms:init_platform(game.forces.player.platforms[sel])
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
