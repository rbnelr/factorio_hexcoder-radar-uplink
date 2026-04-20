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

-- TODO: INFO signal that is included in requests makes sense for std read mode, as user might not be interested in status,
-- just in unfulfilled requests of platform if in orbit, and info helps to not get confused if requests zero or not in orbit
-- but probably should not be sent when in raw mode (move it into combinator, not on platform CC)
-- it could be annoying if it's something to filter out, but the alternative might be filtering out all status signals if you want it on a single wire
-- could just remove it and require users checking status, or make it customizable, maybe a no-info signals is more useful anyway?

---@class RadarData
---@field id unit_number
---@field entity LuaEntity
---@field status defines.entity_status Last status for power check
---@field sel_sig? Signal
---@field S RadarSettings
---@field dcs? table<string, LuaEntity> Hidden combinators that connect to platform readers

-- TODO: sel_orbit_only only makes sense when in dynamic selection mode
-- otherwise it does nothing except act as a filter in the gui
-- I don't want the fixed selection to somehow auto-reset if the platform moves out of orbit
-- so this either disable in gui or keep as filter option, but maybe not as it is confusing?
-- probably should move it to dyn panel
-- Actually -> even in dyn mode, ID selection should just be universal anyway, as failing to select

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
local SIG_ANYTHING = {type="virtual", name="signal-anything"} ---@type SignalID
local SIG_EVERYTHING = {type="virtual", name="signal-everything"} ---@type SignalID
local SIG_CHECK = {type="virtual", name="signal-check"} ---@type SignalID
local SIG_ALERT = {type="virtual", name="signal-alert"} ---@type SignalID

local SIG_PLAT_ID = {type="virtual", name="signal-P"} ---@type SignalID
local SIG_IDX_NUM = {type="virtual", name="signal-number-sign"} ---@type SignalID

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
		-- remember name and id
		T.selected_id = T.selected_platform and T.selected_platform.index or nil
		T.selected_name = T.selected_platform and T.selected_platform.name
		T.selected_platform = nil
	end
	local tags = ghost.tags or {}
	tags["hexcoder_radar_uplink"] = T
	ghost.tags = tags
end
---@param tags table?
---@param as_force LuaForce
---@return RadarSettings?
function M.tags_to_settings(tags, as_force)
	local T = tags and tags["hexcoder_radar_uplink"]
	if not T then return nil end
	
	local S = util.table.deepcopy(T)
	if S.mode == "comms" then
		-- TODO
	else
		-- get platform via id, check name and fallback to name-based search
		if S.selected_id then
			local platforms = as_force.platforms
			S.selected_platform = platforms[S.selected_id]
			if not (S.selected_platform and S.selected_platform.name == S.selected_name) then
				for _, pl in pairs(platforms) do
					if pl.name == S.selected_name then S.selected_platform = pl break end
				end
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
	std = { ---@type CircRG[]
		Sta = { R=true, G=true }, -- R, G
		Req = { R=true, G=true },
	},
	raw = { ---@type CircRG[]
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
		storage.poll_dyn_select:try_remove(data)
	end
end

---@param data RadarData
---@return PlatformData[]
function M.get_platform_list(data)
	if data.S.sel_orbit_only then
		return storage.platforms:get_orbiting_platform_list(data.entity.surface)
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
	local plat_data = (platform and platform.valid and platforms:init_platform(platform)) or nil
	assert((plat_data ~= nil) == (platforms.platform_exists(platform) == true))
	--if true then return end
	
	local radar_surf = entity.surface
	local dcs = data.dcs
	
	if not dcs or reconfig then
		if data.S.dyn ~= nil then
			storage.poll_dyn_select:try_add(data)
		else
			storage.poll_dyn_select:try_remove(data)
		end
		
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
		
		local this_plat = radar_surf.platform and platforms:init_platform(radar_surf.platform) or nil
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
	
	local _inR = inR
	local _outR = outR
	local _circR = circR
	
	local scStatCtrl = dcs.Sta.get_control_behavior() --[[@as LuaDeciderCombinatorControlBehavior]]
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
		
	local sel_sig = data.sel_sig
	
	if plat_data == nil then
		-- return alert if not successfully connected
		
		---@type DeciderCombinatorParameters
		local stat = {conditions={
			{first_signal=SIG_EVERYTHING, constant=0, comparator="=", first_signal_networks=netR},
		},outputs={
			-- Alert signal to inform that connection failed
			-- => non existant ID or index out of bounds
			{signal=SIG_ALERT, copy_count_from_input=false},
			-- Remember select signal that was used (P or #)
			-- => user does not have to keep state, no memory cells or clock signals, TODO: circuit actually reasonable now?
			sel_sig and {signal=sel_sig.signal, copy_count_from_input=false, constant=sel_sig.count} or nil
		}}

		scStatCtrl.parameters = stat
	else
		--game.print("reconnect!")
		
		-- return status if connected
		
		local stat = {conditions={
			{first_signal=SIG_ANYTHING, constant=0, comparator="!=", first_signal_networks=netR}
		},outputs={
			{signal=SIG_EVERYTHING, copy_count_from_input=true, networks=netR},
			sel_sig and {signal=sel_sig.signal, copy_count_from_input=false, constant=sel_sig.count} or nil
		}}
		scStatCtrl.parameters = stat
		
		-- connect DCs to platform if platform initialized
		local pl = plat_data.readers
		
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
			local plConsMats = pl.build_mats_raw.get_wire_connectors(true)
			
			dcReqR.connect_to(plReq[_outR], false, HIDDEN)
			dcOtwR.connect_to(plOtw[_outR], false, HIDDEN)
			dcInvR.connect_to(plInv[_outR], false, HIDDEN)
			--dcInvSlotsR.connect_to(plInvSlots[_outR], false, HIDDEN)
			dcInvSlotsR.connect_to(plConsMats[_outR], false, HIDDEN) -- temp HACK
		end
	end
end

-- TODO: refresh is a bad term, this actually reconfigures world state based on configuration data usually coming from ui
-- -> reconfigure is full data change,  -> reconnect is if only selection has changed and is called by dynamic selection polling after detecting change
---@param data RadarData
---@param sel_changed_only? boolean
function M.refresh_radar(data, sel_changed_only)
	local entity = data.entity
	if not entity.valid then return end
	local id = data.id
	--game.print("refresh_radar: ".. serpent.block(data))
	
	-- write tags to ghosts on change (ui seems to get a copy, possibly because entity.tags is behind API which copies)
	if entity.type == "entity-ghost" then
		M.set_tags(entity, data.S)
		return -- data is not in storage for ghost entities
	end
	
	if data.S.mode == "comms" then
		clear_dcs(data)
		storage.poll_dyn_select:try_remove(data)
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
	assert(entity and entity.valid)
	
	local id = entity.unit_number
	local data = storage.radars[id]
	if not data then
		local S
		if copy_settings then
			S = util.table.deepcopy(copy_settings)
		else
			local tags = M.tags_to_settings(entity.tags, entity.force --[[@as LuaForce]])
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
---@param entity LuaEntity
---@return LuaSpacePlatform?, Signal? sel_sig
local function dyn_select_platform(data, entity)
	local S = data.S
	local wireR = S.dyn.R and circR or nil
	local wireG = S.dyn.G and circG or nil
	
	local wires1 = wireR or wireG
	local wires2 = wireR and wireG
	if not wires1 then
		return nil
	end
	
	local id
	if wires2 == nil then id = entity.get_signal(SIG_PLAT_ID, wires1)
	                 else id = entity.get_signal(SIG_PLAT_ID, wires1, wires2) end
	--local id = entity.get_signal(SIG_PLAT_ID, wires1, wires2) -- this does not work despite  extra_wire_connector_id :: defines.wire_connector_id?
	-- is there actually function overloading for userdata functions?
	if id > 0 then
		local plat_data = storage.platforms[id]
		return plat_data and plat_data.entity, {signal=SIG_PLAT_ID, count=id}
	end
	
	local idx
	if wires2 == nil then idx = entity.get_signal(SIG_IDX_NUM, wires1)
	                 else idx = entity.get_signal(SIG_IDX_NUM, wires1, wires2) end
	if idx > 0 then
		local list = M.get_platform_list(data)
		
		local plat_data = list[idx]
		return plat_data and plat_data.entity, {signal=SIG_IDX_NUM, count=idx}
	end
	
	return nil
end

---@param data RadarData
function M.poll_dyn_select(data)
	local entity = data.entity
	if not entity.valid then return end
	
	local new_sel, sel_sig = dyn_select_platform(data, entity)
	local old_sel = data.S.selected_platform
	if old_sel ~= new_sel then
		data.S.selected_platform = new_sel
		data.sel_sig = sel_sig
		
		-- utility/list_box_click
		-- utility/entity_settings_pasted
		-- utility/smart_pipette
		--entity.surface.play_sound{ path="utility/entity_settings_pasted", position=entity.position, volume_multiplier=1.25, override_sound_type="game-effect" }
		--entity.surface.play_sound{ path="utility/smart_pipette", position=entity.position, volume_multiplier=5.0, override_sound_type="game-effect" }
		
		entity.surface.play_sound{ path="hexcoder_radar_uplink-sel-switch-sound1", position=entity.position }
		entity.surface.play_sound{ path="hexcoder_radar_uplink-sel-switch-sound2", position=entity.position }
		
		M.refresh_radar(data, true)
		
		refresh_gui(data)
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

function M.refresh_all_radars()
	for _,data in pairs(storage.radars) do
		M.refresh_radar(data)
	end
end

return M