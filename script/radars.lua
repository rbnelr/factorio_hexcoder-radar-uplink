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
---@field idx_sig? integer if selected by list index via dynamic selection, keep outputting index for convenience
---@field S RadarSettings
-- Hidden combinators that connect to platform readers, store red input wire directly for efficiency, entity is .owner
---@field dcsR? table<string, LuaWireConnector>
---@field dcStatCtrl? LuaDeciderCombinatorControlBehavior
---@field ccPulse? LuaConstantCombinatorControlBehavior

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
---@field selected_platform? PlatformData Selected platform
---@field dyn? CircRG
---@field dyn_text? string
---@field read_mode? "std"|"raw"
---@field read? ReadStd|ReadRaw

-- Hidden wire for hidden circuits, can visualize using wire_origin.player in debug mode
local HIDDEN = DEBUG and defines.wire_origin.player or defines.wire_origin.script

local STATUS_WORKING = defines.entity_status.working
local W = defines.wire_connector_id
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
local SIG_INFO = {type="virtual", name="signal-info"} ---@type SignalID
local SIG_PLAT_ID = {type="virtual", name="signal-P"} ---@type SignalID
local SIG_LIST_IDX = {type="virtual", name="signal-number-sign"} ---@type SignalID
local SIG_SWITCH_PULSE = { ---@type LogisticFilter
	value={type="virtual", name="signal-rightwards-leftwards-arrow", quality="normal"},
	min=1
}

-----@type DeciderCombinatorParameters
--local EACH_AND_INFO = {conditions={
--	-- !=0 => pass everything
--	{first_signal=SIG_EACH, comparator="!=", constant=0, first_signal_networks=netR}
--},outputs={
--	{signal=SIG_EACH, copy_count_from_input=true, networks=netR},
--	{signal=SIG_INFO, copy_count_from_input=true, networks=netG},
--}}

-----@type DeciderCombinatorParameters
--local EACH_POSITIVE = {conditions={
--	{first_signal=SIG_EACH, comparator=">", constant=0, first_signal_networks=netR}
--},outputs={
--	{signal=SIG_EACH, copy_count_from_input=true, networks=netR}
--}}

-- pass along each positive signal from platform (on Red)
-- if check signal (INFO) > 0 (on Green)
---@type DeciderCombinatorParameters
local DATA_DC_PARAMS = {conditions={
	{first_signal=SIG_EACH, comparator=">", constant=0, first_signal_networks=netR},
	{first_signal=SIG_INFO, comparator=">", constant=0, first_signal_networks=netG, compare_type="and"}
},outputs={
	{signal=SIG_EACH, copy_count_from_input=true, networks=netR}
}}

local util = require("util")
local radar_channels = require("script.radar_channels")

local M = {}

---@class ReadStd
---@field Sta CircRG
---@field Req CircRG

---@class ReadRaw
---@field Sta CircRG
---@field Req CircRG
---@field Otw CircRG
---@field Inv CircRG

---@class CircRG
---@field R boolean -- red circuit
---@field G boolean -- green circuit

M.defaults = {
	sel_orbit_only = true,
	dyn = { ---@type CircRG
		R=false, G=true, -- R, G
	},
	std = { ---@type ReadStd
		Sta = { R=true, G=true }, -- R, G
		Req = { R=true, G=true },
	},
	raw = { ---@type ReadRaw
		Sta = { R=false, G=true },
		Req = { R=false, G=true },
		Otw = { R=true, G=false },
		Inv = { R=true, G=false },
	},
}

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

---@param data RadarData
local function clear_dcs(data)
	if data.dcsR then
		for _,v in pairs(data.dcsR) do
			v.owner.destroy()
		end
		data.dcsR = nil
		
		data.ccPulse.entity.destroy()
	end
end

---@param id unit_number
function M.delete_radar(id)
	local data = storage.radars[id]
	if data then
		clear_dcs(data)
		
		--if  data.dynCC then
		--	data.dynCC.destroy()
		--end
		
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
	local radar_surf = entity.surface
	local dcsR = data.dcsR
	
	local S = data.S
	local plat_data = data.S.selected_platform
	local read_mode = data.S.read_mode
	
	local _inR = inR
	local _outR = outR
	local _circR = circR
	
	if not dcsR or reconfig then
		local base_x = entity.position.x
		local base_y = entity.position.y
		
		--if data.dynCC then
		--	data.dynCC.destroy()
		--end
		
		if S.dyn ~= nil then
			storage.poll_dyn_select:try_add(data)
			
			--local dynCC = radar_surf.create_entity{
			--	name="hexcoder_radar_uplink-sel_module", force=entity.force,
			--	position={base_x-1.25, base_y-0.15}, snap_to_grid=false,
			--	direction=defines.direction.west
			--} ---@cast dynCC -nil
			--
			--dynCC.destructible = false
			--dynCC.combinator_description = "dynCC"
			--data.dynCC = dynCC
		else
			storage.poll_dyn_select:try_remove(data)
		end
		
		local allow_unchecked = ALLOW_INTERPL and read_mode == "raw"
		local radar_planet = radar_surf.planet -- nil if radar placed on space platform
		
		-- Non-status modes read signals only if platform is in orbit of radar via a planet check in combinator
		---@type DeciderCombinatorParameters
		local params_check
		if allow_unchecked then
			-- If allowing interplanetary comms, raw read modes always work
			-- (note that requests still depend on which planet is being currently orbited)
			-- still keep check combinator when unchecked to output info signal, and so other code is simpler
			---@type DeciderCombinatorParameters
			params_check = {conditions={
				{first_signal=SIG_ANYTHING, comparator="!=", constant=0, first_signal_networks=netR}
			}, outputs={
				{signal=SIG_INFO, copy_count_from_input=false, constant=1}
			}}
		elseif radar_planet then
			-- radar on ground: check platform planet directly
			-- could also add one loc CC per planet like with platform
			---@type DeciderCombinatorParameters
			params_check = {conditions={
				{first_signal={type="space-location", name=radar_planet.name}, comparator="=", constant=3, first_signal_networks=netR}
			}, outputs={
				{signal=SIG_INFO, copy_count_from_input=false, constant=1}
			}}
		else
			-- radar on platform: check platform location against other platform
			-- loc contains only planet signals, so this allows connecting to other platforms in same orbit
			-- but not to anything but itself while in connection
			params_check = {conditions={
				-- this platform planet == other platform planet  (or space connection but only in same direction)
				{first_signal=SIG_EVERYTHING, comparator="=", second_signal=SIG_EVERYTHING, first_signal_networks=netR, second_signal_networks=netG},
				--  TODO:
				{first_signal=SIG_EVERYTHING, comparator="=", constant=3, first_signal_networks=netR, },
			}, outputs={
				{signal=SIG_INFO, copy_count_from_input=false, constant=1}
			}}
		end
		
		if not dcsR then
			dcsR = {}
			data.dcsR = dcsR
			
			-- connection switch pulse generator CC
			-- needs to be somewhere else if wanted for comms mode
			local pcc = radar_surf.create_entity{
				name="hexcoder_radar_uplink-pulsegen_cc", force=entity.force,
				position={base_x-1.25, base_y-1.25}, snap_to_grid=false,
				direction=defines.direction.south
			} ---@cast pcc -nil
			
			pcc.destructible = false
			pcc.combinator_description = "connection switch pulse generator CC"
			
			data.ccPulse = pcc.get_or_create_control_behavior() --[[@as LuaConstantCombinatorControlBehavior]]
			data.ccPulse.sections[1].set_slot(1, SIG_SWITCH_PULSE)
			data.ccPulse.enabled = false
		end
		
		local radarW = entity.get_wire_connectors(true)
		local working = data.status == STATUS_WORKING -- powered and not frozen
		
		---@param x number
		---@param y number
		---@param name string
		---@param params DeciderCombinatorParameters?
		---@param config CircRG?
		---@param chkG? LuaWireConnector[]
		---@return LuaWireConnector[]?
		local function update_combinator(x,y, name, params, config, chkG)
			local dc_inR = dcsR[name]
			if not (config or name=="Check") then
				if dc_inR then
					local dc = dc_inR and dc_inR.owner
					dc.destroy()
					dcsR[name] = nil
				end
				
				return nil
			else
				local dc
				if dc_inR then
					dc = dc_inR.owner
				else
					dc = radar_surf.create_entity{
						name="hexcoder_radar_uplink-dc", force=entity.force,
						position={base_x+x-1.5, base_y+y}, snap_to_grid=false,
						direction=defines.direction.south
					} ---@cast dc -nil
					
					dc.destructible = false
					dc.combinator_description = name
					
					dcsR[name] = dc.get_wire_connectors(true)[_inR]
				end
				
				if params then
					local ctrl = dc.get_or_create_control_behavior() --[[@as LuaDeciderCombinatorControlBehavior]]
					ctrl.parameters = params
				end
				
				local dc_conn = dc.get_wire_connectors(true)
				dc_conn[inG].disconnect_all()
				dc_conn[outR].disconnect_all()
				dc_conn[outG].disconnect_all()
				
				-- disconnect on power out, but keep combinators
				-- TODO: optimize by moving to seperate case?
				if working and config then
					if config.R then dc_conn[outR].connect_to(radarW[circR], false, HIDDEN) end
					if config.G then dc_conn[outG].connect_to(radarW[circG], false, HIDDEN) end
				end
				
				if chkG then
					dc_conn[inG].connect_to(chkG, false, HIDDEN)
				end
				
				return dc_conn
			end
		end
		
		local readRG = S.read ---@cast readRG -nil
		local chk = update_combinator(3   ,-1, "Check",    params_check) ---@cast chk -nil
		local chkG = chk[outG]
		
		update_combinator(0   , 1, "Sta",      nil, readRG.Sta, chkG)
		update_combinator( .75, 1, "Req",      DATA_DC_PARAMS, readRG.Req, chkG)
		update_combinator(1.5 , 1, "Otw",      DATA_DC_PARAMS, readRG.Otw, chkG)
		update_combinator(2.25, 1, "Inv",      DATA_DC_PARAMS, readRG.Inv, chkG)
		
		local this_plat = entity.surface.platform
		if this_plat and this_plat.valid then
			local this_plat_data = storage.platforms:init_platform(this_plat)
			local pl2LocCC = this_plat_data.readers.loc_cc.get_wire_connectors(true)
			chk[inG].connect_to(pl2LocCC[circG], false, HIDDEN)
		end
		
		data.dcStatCtrl = dcsR.Sta.owner.get_or_create_control_behavior() --[[@as LuaDeciderCombinatorControlBehavior]]
		
		local ccPulse = data.ccPulse.entity.get_wire_connectors(true)
		ccPulse[circR].disconnect_all()
		ccPulse[circG].disconnect_all()
		local pulseRG = readRG.Sta
		if pulseRG then
			if pulseRG.R then ccPulse[circR].connect_to(radarW[circR], false, HIDDEN) end
			if pulseRG.G then ccPulse[circG].connect_to(radarW[circG], false, HIDDEN) end
		end
	end
	
	local dcCheckR    = dcsR.Check
	local dcStatR     = dcsR.Sta
	local dcReqR      = dcsR.Req
	local dcOtwR      = nil
	local dcInvR      = nil
	local dcInvSlotsR = nil
	
	dcCheckR   .disconnect_all()
	dcStatR    .disconnect_all()
	dcReqR     .disconnect_all()
	if read_mode ~= "std" then
		dcOtwR      = dcsR.Otw
		dcInvR      = dcsR.Inv
		dcOtwR     .disconnect_all()
		dcInvR     .disconnect_all()
	end
	
	--game.print("reconnect!")
		
	local idx_sel = data.idx_sig
	-- pass along each signal from platform status without check (on Red)
	-- pass check signal as 'info is available' signal
	-- output selection index if selected through index via dynamic selection
	data.dcStatCtrl.parameters = {conditions={
		{first_signal=SIG_ANYTHING, comparator="!=", constant=0, first_signal_networks=netR}
	},outputs={
		{signal=SIG_EVERYTHING, copy_count_from_input=true, networks=netR},
		{signal=SIG_INFO, copy_count_from_input=true, networks=netG},
		idx_sel and {signal=SIG_LIST_IDX, copy_count_from_input=false, constant=idx_sel} or nil
	}}
	
	data.ccPulse.enabled = true
	
	if plat_data then
		
		-- connect DCs to platform if platform initialized
		local pl = plat_data.readers
		
		-- split location status see platform init
		local plLocCC = pl.loc_cc.get_wire_connectors(true)
		local plStat = pl.stat.get_wire_connectors(true)
		dcCheckR.connect_to(plLocCC[_circR], false, HIDDEN)
		dcStatR.connect_to(plStat[_outR], false, HIDDEN)
		
		if read_mode == "std" then
			local plReq = pl.req.get_wire_connectors(true)
			
			dcReqR.connect_to(plReq[_outR], false, HIDDEN)
		else
			local plReq = pl.req_raw.get_wire_connectors(true)
			local plOtw = pl.otw_raw.get_wire_connectors(true)
			local plInv = pl.inv_raw.get_wire_connectors(true)
			
			dcReqR.connect_to(plReq[_outR], false, HIDDEN)
			dcOtwR.connect_to(plOtw[_outR], false, HIDDEN) ---@diagnostic disable-line
			dcInvR.connect_to(plInv[_outR], false, HIDDEN) ---@diagnostic disable-line
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
	
	if DEBUG then game.print("after refresh_radar: ".. serpent.line({
			--data.S,
			game.tick,
			data.idx_sig, data.S.selected_platform and data.S.selected_platform.name
		}), {
		sound = (sel_changed_only and defines.print_sound.never or defines.print_sound.use_player_settings)
	}) end
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
---@return PlatformData?, integer? idx
local function dyn_select_platform(data, entity)
	local S = data.S
	local wireR = S.dyn.R and circR or nil
	local wireG = S.dyn.G and circG or nil
	
	-- just use change detection with memory cell here, its faster, but may want to restrict wire to R or G
	local wires1 = wireR or wireG
	local wires2 = wireR and wireG
	if wires1 then
		local id
		if wires2 == nil then id = entity.get_signal(SIG_PLAT_ID, wires1)
		                 else id = entity.get_signal(SIG_PLAT_ID, wires1, wires2) end
		--local id = entity.get_signal(SIG_PLAT_ID, wires1, wires2) -- this does not work despite  extra_wire_connector_id :: defines.wire_connector_id?
		-- is there actually function overloading for userdata functions?
		if id > 0 then
			local plat_data = storage.platforms[id]
			return plat_data
		end
		
		local idx
		if wires2 == nil then idx = entity.get_signal(SIG_LIST_IDX, wires1)
		                 else idx = entity.get_signal(SIG_LIST_IDX, wires1, wires2) end
		if idx > 0 then
			local list = M.get_platform_list(data)
			
			local plat_data = list[idx]
			return plat_data, idx
		end
	end
	
	return nil
end

---@param data RadarData
function M.poll_dyn_select(data)
	local entity = data.entity
	if not entity.valid then return end
	
	local new_sel, idx = dyn_select_platform(data, entity)
	
	-- selected new platform, or selected via different signal
	-- (same signal can have platform change because orbital filter)
	-- same platform still requires selected signal output to be updated (TODO: could latch this information?)
	if new_sel == data.S.selected_platform and idx == data.idx_sig then
		return
	end
	
	data.S.selected_platform = new_sel
	data.idx_sig = idx
	
	--entity.surface.play_sound{ path="utility/entity_settings_pasted", position=entity.position, volume_multiplier=1.25, override_sound_type="game-effect" }
	--entity.surface.play_sound{ path="utility/smart_pipette", position=entity.position, volume_multiplier=5.0, override_sound_type="game-effect" }
	entity.surface.play_sound{ path="hexcoder_radar_uplink-sel-switch-sound1", position=entity.position }
	entity.surface.play_sound{ path="hexcoder_radar_uplink-sel-switch-sound2", position=entity.position }
	
	M.refresh_radar(data, true)
	
	refresh_gui(data)
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