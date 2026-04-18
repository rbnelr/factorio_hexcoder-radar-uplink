--[[ Radars:
	Originally created radar data on gui click, then if settings were ever returned to default (vanilla mode)
	  data was deleted to minimize storage and potential processing cost
	But this was brittle, so now all radars should always be stored in storage.radars (unit_number -> RadarData)
	Data stores various data, RadarSettings (data.S) store actual user settings made in GUI, these are converted to and from tags in ghost entities and blueprints
	ghost entities itself support gui customization, init_radar and refresh_radar both handle ghosts by generating data that is not in storage but then gets stored by gui
	circuits (DCs) are created and deleted depending on settings
	init_radar lazily creates data and calls refresh (called in mod init and on any radar spawn)
	refresh_radar fully updates circuits to correspond to settings
]]

---@class RadarData
---@field id unit_number
---@field entity LuaEntity
---@field status defines.entity_status Last status for power check
---@field S RadarSettings
---@field dcs? table<string, LuaEntity> Hidden combinators that connect to platform readers

-- TODO: remove Settings and merge using ---@class RadarData : RadarSettings? use strict to luals checks everything?
---@class RadarSettings
---@field mode "comms"|"platforms" Operation mode, comms for vanilla global channel or named channels, platforms for platform reading
---@field sel_orbit_only? boolean Fiter platform list to just platforms in orbit? (Also affects selection by index)
---@field selected_channel? channel_id
---@field selected_platform? LuaSpacePlatform Selected platform, should already be built but could be scheduled_for_deletion
---@field dyn? CircRG
---@field dyn_text? string
---@field read_mode? "std"|"raw"
---@field read? table<string, CircRG>

---@class CircRG
---@field R boolean -- red circuit
---@field G boolean -- green circuit

local W = defines.wire_connector_id
local HIDDEN = defines.wire_origin.script
local netR = {red=true, green=false}
local netG = {red=false, green=true}
local circR = W.circuit_red
local circG = W.circuit_green
local inR = W.combinator_input_red
local inG = W.combinator_input_green
local outR = W.combinator_output_red
local outG = W.combinator_output_green

local SIG_EACH = {type="virtual", name="signal-each"} ---@type SignalID
local SIG_EVERYTHING = {type="virtual", name="signal-everything"} ---@type SignalID
local SIG_CHECK = {type="virtual", name="signal-check"} ---@type SignalID

---@type DeciderCombinatorParameters
local PASS_EACH = {conditions={
	{first_signal=SIG_EACH, constant=0, comparator="!=", first_signal_networks=netR}
},outputs={
	{signal=SIG_EACH, copy_count_from_input=true, networks=netR}
}}

---@type DeciderCombinatorParameters
local EACH_RED_GT_ZERO = {conditions={
	{first_signal=SIG_EACH, constant=0, comparator=">", first_signal_networks=netR}
},outputs={
	{signal=SIG_EACH, copy_count_from_input=true, networks=netR}
}}

---@type DeciderCombinatorParameters
local EACH_RED_GT_ZERO_IF_CHECK_GREEN = {conditions={
	{first_signal=SIG_EACH, constant=0, comparator=">", first_signal_networks=netR},
	{first_signal=SIG_CHECK, constant=0, comparator=">", first_signal_networks=netG, compare_type="and"}
},outputs={
	{signal=SIG_EACH, copy_count_from_input=true, networks=netR}
}}

local util = require("util")
local radar_channels = require("script.radar_channels")

local M = {}

---@param e LuaEntity?
---@return boolean
function M.is_radar(e)
	return e and e.valid and (e.name == "radar" or (e.type == "entity-ghost" and e.ghost_name == "radar")) or false
end

---@param ghost LuaEntity|BlueprintEntity
---@param S RadarSettings
function M.set_tags(ghost, S)
	-- make sure selection works across saves
	local T = util.table.deepcopy(S) --[[@as table]]
	if T.mode == "comms" then
		T.selected = nil -- TODO
	else
		T.selected_id = T.selected_platform and T.selected_platform.index or nil
		local platf = T.selected_id and ghost.force.platforms[T.selected_id] or nil
		T.selected_name = platf and platf.name
		T.selected_platform = nil
	end
	local tags = ghost.tags or {}
	tags["hexcoder_radar_uplink"] = S
	ghost.tags = tags
end
---@param ghost LuaEntity|BlueprintEntity
---@return RadarSettings?
function M.tags_to_settings(ghost)
	local T = ghost.tags and ghost.tags["hexcoder_radar_uplink"]
	if not T then return nil end
	
	local S = util.table.deepcopy(T)
	if S.mode == "comms" then
		-- TODO
	else
		local platforms = ghost.force.platforms
		S.selected_platform = platforms[S.selected_id]
		if not (S.selected_platform and S.selected_platform.name == S.selected_name) then
			for _, pl in pairs(platforms) do -- id not found, search by name
				if pl.name == S.selected_name then S.selected_platform = pl break end
			end
		end
		S.selected_id = nil
		S.selected_name = nil
	end
	return S --[[@as RadarSettings]]
end

---@param ghost LuaEntity|BlueprintEntity
---@param entity_id unit_number
---@return boolean added
function M.settings_to_tags(ghost, entity_id)
	local data = storage.radars[entity_id]
	if data then
		M.set_tags(ghost, data.S)
		return true
	end
	return false
end

M.radar_defaults = {
	sel_orbit_only = true,
	dyn = { ---@type CircRG
		R=true, G=true, -- R, G
	},
	pl_std = { ---@type CircRG[]
		Sta = { R=true, G=true }, -- R, G
		Req = { R=true, G=true },
	},
	pl_raw = { ---@type CircRG[]
		Sta = { R=false, G=true },
		Req = { R=false, G=true },
		Otw = { R=true, G=false },
		Inv = { R=true, G=false },
		InvSlots = { R=false, G=false },
	}
}

---@param data RadarData
local function clear_dcs(data)
	if data.dcs then
		for _,v in pairs(data.dcs) do
			v.destroy()
		end
		data.dcs = nil
	end
end

---@param id unit_number
function M.delete_radar(id)
	local data = storage.radars[id]
	if data then
		clear_dcs(data)
		storage.radars[id] = nil
		
		storage.poll_power_check:remove(data)
	end
end

---@param data RadarData
---@return PlatformData[], string? planet_name
function M.get_platform_list(data)
	local planet = data.S.sel_orbit_only and data.entity.surface.planet or nil
	if planet then
		return storage.platforms:get_orbiting_platform_list(planet)
	else
		return storage.platforms.all_sorted
	end
end

---@param entity LuaEntity
---@param data RadarData
---@param reconfig boolean
local function refresh_radar_platform_mode(entity, data, reconfig)
	local platforms = storage.platforms
	local platform = data.S.selected_platform
	local plat_data = platform and platforms:init_platform(platform) or nil
	assert((platform ~= nil) == (platforms.platform_exists(platform) == true))
	--if true then return end
	
	local radar_surf = entity.surface
	local dcs = data.dcs
	
	if not dcs or reconfig then
		local radar_planet = radar_surf.planet -- nil if radar placed on space platform
		
		local allow_unchecked = ALLOW_INTERPL and data.S.read_mode == "raw"
		
		local params_check
		if radar_planet then
			-- radar on ground: check platform planet directly
			local planet_sig = {type="space-location", name=radar_planet.name}
			---@type DeciderCombinatorParameters
			params_check = {conditions={
				{first_signal=planet_sig, constant=3, comparator="=", first_signal_networks=netR }
			},outputs={
				{signal=SIG_CHECK, copy_count_from_input=false, constant=1}
			}}
		else
			-- radar on platform: check platform planet via comparison
			---@type DeciderCombinatorParameters
			params_check = {conditions={
				{first_signal=SIG_EVERYTHING, second_signal=SIG_EVERYTHING, comparator="=", constantfirst_signal_networks=netR, second_signal_networks=netG } -- all(R == G)
			},outputs={
				{signal=SIG_CHECK, copy_count_from_input=false, constant=1}
			}}
		end
		
		local params_detail
		if allow_unchecked then
			-- If allowing interplanetary comms, raw read modes always work
			-- (note that requests still depend on which planet is being currently orbited)
			params_detail = EACH_RED_GT_ZERO
		else
			-- Non-status modes read signals only if platform is in orbit of radar via a planet check in combinator
			params_detail = EACH_RED_GT_ZERO_IF_CHECK_GREEN
		end
		
		local base_x = entity.position.x-1.5
		local base_y = entity.position.y
		local function make_combinator(x,y, descr)
			local dc = radar_surf.create_entity{
				name="hexcoder_radar_uplink-dc", force=entity.force,
				position={base_x+x, base_y+y}, snap_to_grid=false,
				direction=defines.direction.south
			} ---@cast dc -nil
			dc.destructible = false
			dc.combinator_description = descr
			return dc
		end
		
		if not dcs then -- keep conbinators if stayed in platforms mode
			dcs = {}
			dcs.Sta = make_combinator(0,1, "platform status")
			dcs.Req = make_combinator(.75,1, "platform req")
			dcs.Otw = make_combinator(1.5,1, "platform otw")
			dcs.Inv = make_combinator(2.25,1, "platform inv")
			dcs.InvSlots = make_combinator(3,1, "platform slots")
			dcs.Check = make_combinator(3,-1, "platform location check")
			data.dcs = dcs
		end
		
		local rad = entity.get_wire_connectors(true)
		local working = data.status == defines.entity_status.working -- powered and not frozen
		
		---@param dc LuaEntity
		---@param params DeciderCombinatorParameters
		---@param rg CircRG?
		local function config_combinator(dc, params, rg)
			local ctrl = dc.get_control_behavior() --[[@as LuaDeciderCombinatorControlBehavior]]
			ctrl.parameters = params
			
			rg = working and rg or nil
			local con = dc.get_wire_connectors(true)
			
			con[inG].disconnect_all(HIDDEN)
			con[outR].disconnect_all(HIDDEN)
			con[outG].disconnect_all(HIDDEN)
			if rg and rg.R then con[outR].connect_to(rad[circR], false, HIDDEN) end
			if rg and rg.G then con[outG].connect_to(rad[circG], false, HIDDEN) end
			
			return con
		end
		
		-- Status DC just passes along info (1-tick delay one-way signal bridge)
		                   config_combinator(dcs.Sta, PASS_EACH, data.S.read.Sta)
		local dcReq      = config_combinator(dcs.Req, params_detail, data.S.read.Req)
		local dcOtw      = config_combinator(dcs.Otw, params_detail, data.S.read.Otw)
		local dcInv      = config_combinator(dcs.Inv, params_detail, data.S.read.Inv)
		local dcInvSlots = config_combinator(dcs.InvSlots, params_detail, data.S.read.InvSlots)
		local dcCheck    = config_combinator(dcs.Check, params_check)
		
		local this_plat = radar_surf.platform and M.platform_valid(radar_surf.platform) and M.init_platform(radar_surf.platform) or nil
		
		if this_plat then
			local pl2LocCC = this_plat.readers.loc_cc.get_wire_connectors(true)
			dcCheck[inG].connect_to(pl2LocCC[circG], false, HIDDEN)
		end
		
		local dcCheckG = dcCheck[outG]
		if data.S.read_mode == "std" then
			dcReq[inG].connect_to(dcCheckG, false, HIDDEN)
		else
			dcReq[inG].connect_to(dcCheckG, false, HIDDEN)
			dcOtw[inG].connect_to(dcCheckG, false, HIDDEN)
			dcInv[inG].connect_to(dcCheckG, false, HIDDEN)
			dcInvSlots[inG].connect_to(dcCheckG, false, HIDDEN)
		end
	end
	
	if plat_data then
		--game.print("reconnect!")
		
		-- connect DCs to platform if platform initialized
		local pl = plat_data.readers
	
		local _inR = inR
		local _outR = outR
		local _circR = circR
		
		local dcStatR     = dcs.Sta.get_wire_connectors(false)[_inR]
		local dcReqR      = dcs.Req.get_wire_connectors(false)[_inR]
		local dcOtwR      = dcs.Otw.get_wire_connectors(false)[_inR]
		local dcInvR      = dcs.Inv.get_wire_connectors(false)[_inR]
		local dcInvSlotsR = dcs.InvSlots.get_wire_connectors(false)[_inR]
		local dcCheckR    = dcs.Check.get_wire_connectors(false)[_inR]
		
		dcStatR    .disconnect_all(HIDDEN)
		dcReqR     .disconnect_all(HIDDEN)
		dcOtwR     .disconnect_all(HIDDEN)
		dcInvR     .disconnect_all(HIDDEN)
		dcInvSlotsR.disconnect_all(HIDDEN)
		dcCheckR   .disconnect_all(HIDDEN)
		
		local plLocCC = pl.loc_cc.get_wire_connectors(true)
		local plStat = pl.stat.get_wire_connectors(true)
		dcCheckR.connect_to(plLocCC[_circR], false, HIDDEN)
		dcStatR .connect_to(plStat[_outR], false, HIDDEN)
		
		if data.S.read_mode == "std" then
			local plReq = pl.req.get_wire_connectors(true)
			
			dcReqR.connect_to(plReq[_outR], false, HIDDEN)
		else
			local plReq = pl.req_raw.get_wire_connectors(true)
			local plOtw = pl.otw_raw.get_wire_connectors(true)
			local plInv = pl.inv_raw.get_wire_connectors(true)
			local plInvSlots = pl.inv_slots_raw.get_wire_connectors(true)
			
			dcReqR.connect_to(plReq[_outR], false, HIDDEN)
			dcOtwR.connect_to(plOtw[_outR], false, HIDDEN)
			dcInvR.connect_to(plInv[_outR], false, HIDDEN)
			dcInvSlotsR.connect_to(plInvSlots[_outR], false, HIDDEN)
		end
	end
end

---@param data RadarData
---@param sel_changed_only? boolean
function M.refresh_radar(data, sel_changed_only)
	local entity = data.entity
	local id = data.id
	--game.print("refresh_radar: ".. serpent.block(data))
	
	-- write tags to ghosts on change (ui seems to get a copy, possibly because entity.tags is behind API which copies)
	if entity.type == "entity-ghost" then
		M.set_tags(entity, data.S)
		return -- data is not in storage for ghost entities
	end
	
	if data.S.mode == "comms" then
		clear_dcs(data)
	elseif data.S.mode == "platforms" then
		refresh_radar_platform_mode(entity, data, not sel_changed_only)
	end
	
	radar_channels.update_radar_channel(data)
	
	storage.radars[id] = data
	
	if DEBUG then game.print("after refresh_radar: ".. serpent.block(data)) end
end
---@param entity LuaEntity
---@param copy_settings RadarSettings?
---@return RadarData
function M.init_radar(entity, copy_settings)
	local id = entity.unit_number
	local data = storage.radars[id]
	if not data then
		local S
		if copy_settings then
			S = util.table.deepcopy(copy_settings)
		else
			local tags = M.tags_to_settings(entity)
			if tags then -- handle allowing gui from ghost entities
				S = tags
			else
				-- default settings if radar not registered in storage
				-- Vanilla-equivalent global comms mode
				S = { -- settings
					mode = "comms",
					selected_channel = 1, -- "[Global]"
				}
			end
		end ---@cast S RadarSettings
		
		data = {
			id = id,
			entity = entity,
			status = entity.status,
			S = S
		}
		
		if entity.type ~= "entity-ghost" then
			storage.poll_power_check:add(data)
			
			script.register_on_object_destroyed(entity)
		end
	end
	
	M.refresh_radar(data)
	return data
end

---@param data RadarData
function M.poll_radar_fast(data)
	local entity = data.entity
	if entity.valid then
		
	end
end

---@param data RadarData
function M.poll_radar(data)
	local entity = data.entity
	if entity.valid then
	
		local new_status = entity.status ---@cast new_status -nil
		if new_status ~= data.status then
			data.status = new_status
			M.refresh_radar(data)
		end
	end
end

function M.refresh_all_custom_radars()
	for _,data in pairs(storage.radars) do
		M.refresh_radar(data)
	end
end

return M