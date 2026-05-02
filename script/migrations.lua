local radars = require("script.radars")
local Platforms = require("script.platforms")

local migrations = {}

--[[ Migration Notes:

	-Be careful about default settings, user-customized radars should use existing settings, not defaults
	
]]

-- First attempt at adding migrations
function migrations.migrate_less0_1_4()
	---@class oldRadarData
	---@field S oldRadarSettings
	
	---@class old_channel_id : integer
	
	---@class oldRadarSettings
	---@field mode "comms"|"platforms"
	---@field sel_orbit_only? boolean
	---@field selected_channel? old_channel_id
	---@field selected_platform? Platform|LuaSpacePlatform|platform_index
	---@field selected? Channel|Platform
	---@field dyn? CircRG|"circuit_red"|"circuit_green"|DynamicSelect
	---@field dyn_text? string
	---@field read_mode? "std"|"raw"
	---@field read? ReadStd|ReadRaw
	
	---@class oldChannels
	---@field next_id old_channel_id
	---@field map table<old_channel_id, oldChannel>
	
	---@class oldChannel
	---@field id old_channel_id
	---@field name string
	---@field is_interplanetary boolean
	
	-- back up old state
	local old_channels = util.table.deepcopy(storage.channels or {}) --[[@as oldChannels|Channels]]
	local old_radars = util.table.deepcopy(storage.radars or {}) --[[@as table<unit_number, oldRadarData>]]
	
	-- create new default state
	migrations.reset()
	
	--storage.channels.next_id = channels.next_id or 1
	--for id,ch in pairs(channels.map) do
	--	if type(id) == "number" and id > 1 and ch and ch.name and id < storage.channels.next_id then
	--		storage.channels.map[id] = { id=id, name=ch.name, is_interplanetary=ch.is_interplanetary or false }
	--	end
	--end
	
	if old_channels.surfaces then
		for sid,surf in pairs(old_channels.surfaces) do
			local surface = game.surfaces[sid]
			if surface then
				for _,ch in pairs(surf.channels or {}) do
					if ch.name then
						storage.channels:init_channel(surface, ch.name, ch.is_interpl)
					end
				end
			end
		end
	end
	
	-- transfer settings from old state to new looked up via radar unit_number
	for id,data in pairs(storage.radars) do
		local surface = data.entity.surface
		local old_data = old_radars[id]
		if old_data and old_data.S then
			
			local S = {}
			S.mode = old_data.S.mode == "platforms" and "platforms" or "comms"
			
			S.sel_orbit_only = old_data.S.sel_orbit_only
			
			local dyn = old_data.S.dyn
			--if type(dyn) == "string" then
			--	S.dyn = util.table.deepcopy(radars.defaults.dyn)
			--	S.dyn.wire = dyn
			--elseif type(dyn) == "table" then
			--	S.dyn = {}
			--	S.dyn.wire = dyn.R and "circuit_red" or dyn.G and "circuit_green" or "circuit_red"
			--	S.dyn.id_sel = dyn.id_sel or radars.defaults.dyn.id_sel
			--	S.dyn.idx_sel = dyn.idx_sel or radars.defaults.dyn.idx_sel
			--	S.dyn.switch_pulse = dyn.switch_pulse or radars.defaults.dyn.switch_pulse
			--	S.dyn.text = dyn.text
			--end
			S.dyn = dyn
			
			if old_data.S.mode == "platforms" then
				S.read_mode = old_data.S.read_mode or "std"
				S.read = {}
				for k,_ in pairs(radars.defaults[S.read_mode]) do ---@diagnostic disable-line
					S.read[k] = old_data.S.read and old_data.S.read[k] or { false, false } -- copy setting or false to avoid affecting existing circuits
				end
				
				local sel = old_data.S.selected_platform or old_data.S.selected
				if type(sel) == "table" then
					S.selected = Platforms.platform_exists(sel.platform) and storage.platforms:init_platform(sel.platform) or nil
				--elseif type(sel) == "userdata" and sel.object_name == "LuaSpacePlatform" then -- only in dev: was never released
				--	S.selected = storage.platforms:init_platform(sel)
				elseif type(sel) == "number" then
					S.selected = storage.platforms:init_platform(game.forces.player.platforms[sel])
				end
			else
				local sel = old_data.S.selected_channel or old_data.S.selected
				if type(sel) == "table" and type(sel.name) == "string" then
					local is_interpl = type(sel.is_interpl) == "boolean" and sel.is_interpl or nil
					S.selected = storage.channels:init_channel(surface, sel.name, is_interpl)
				elseif type(sel) == "string" then
					-- ?
				elseif type(sel) == "number" then
					--sel = old_channels.map[sel]
					--S.selected = make_
				end
			end
			
			data.S = S
			radars.refresh_radar(data)
		end
	end
end

commands.add_command("hexcoder_radar_uplink-migrate", nil, function(command)
	migrations.migrate_less0_1_4()
end)

script.on_configuration_changed(function(data)
	local changes = data.mod_changes["hexcoder-radar-uplink"]
	if not changes then return end
	
	local old = changes.old_version
	if not old then
		migrations.init()
		return
	end
	
	if helpers.compare_versions(old, "0.1.4") < 0 then
		migrations.migrate_less0_1_4()
	end
end)

return migrations
