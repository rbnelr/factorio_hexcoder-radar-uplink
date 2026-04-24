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

---@class (exact) RadarData
---@field id unit_number
---@field entity LuaEntity
---@field status defines.entity_status Last status for power check
---@field sel_idx? integer if selected by list index, keep outputting index for iteration setups with dynamic selection
---@field S RadarSettings
-- Hidden combinators that connect to platform CCs, store red input wire directly for efficiency, entity is .owner
---@field hidden_circ? table<string, LuaEntity>
---@field ccPulseSec1? LuaLogisticSection
---@field ccPulseSec2? LuaLogisticSection
---@field dcCheckR? LuaWireConnector
---@field delayStatR?  LuaWireConnector
---@field delayStatG?  LuaWireConnector
---@field delayReqR?   LuaWireConnector
---@field delayReqG?   LuaWireConnector
---@field delayOtwR?   LuaWireConnector
---@field delayInvR?   LuaWireConnector

-- TODO: sel_orbit_only only makes sense when in dynamic selection mode
-- otherwise it does nothing except act as a filter in the gui
-- I don't want the fixed selection to somehow auto-reset if the platform moves out of orbit
-- so this either disable in gui or keep as filter option, but maybe not as it is confusing?
-- probably should move it to dyn panel
-- Actually -> even in dyn mode, ID selection should just be universal anyway, as failing to select

-- TODO: remove Settings and merge using ---@class RadarData : RadarSettings? use strict to luals checks everything?
---@class (exact) RadarSettings
---@field mode "comms"|"platforms" Operation mode, comms for vanilla global channel or named channels, platforms for platform reading
---@field sel_orbit_only? boolean Fiter platform list to just platforms in orbit? (Also affects selection by index)
---@field selected_channel? channel_id
---@field selected_platform? PlatformData Selected platform
---@field dyn? "circuit_red"|"circuit_green" -- probably not safe to put defines in storage
---@field dyn_text? string
---@field read_mode? "std"|"raw"
---@field read? ReadStd|ReadRaw

-- Hidden wire for hidden circuits, can visualize using wire_origin.player in debug mode
local HIDDEN = DEBUG and defines.wire_origin.player or defines.wire_origin.script

local STATUS_WORKING = defines.entity_status.working
local W = defines.wire_connector_id
local netR = {red=true, green=false}
local netG = {red=false, green=true}
local W_circR = W.circuit_red
local W_circG = W.circuit_green
local W_inR = W.combinator_input_red
local W_inG = W.combinator_input_green
local W_outR = W.combinator_output_red
local W_outG = W.combinator_output_green

local SIG_EVERYTHING   = {type="virtual", name="signal-everything"} ---@type SignalID
local SIG_EACH         = {type="virtual", name="signal-each"} ---@type SignalID
local SIG_ANYTHING     = {type="virtual", name="signal-anything"} ---@type SignalID
local SIG_INFO         = {type="virtual", name="signal-info"} ---@type SignalID
local SIG_PLAT_ID      = {type="virtual", name="signal-P"} ---@type SignalID
local SIG_LIST_IDX     = {type="virtual", name="signal-number-sign"} ---@type SignalID
local SIG_INTERNAL1    = {type="virtual", name="signal-exclamation-mark"} ---@type SignalID
local SIG_SWITCH_PULSE = {type="virtual", name="signal-rightwards-leftwards-arrow"} ---@type SignalID
local SIG_ORBIT_ID     = {type="virtual", name="signal-O"} ---@type SignalID

local SIG_INTERNAL1F = { value={type="virtual", name=SIG_INTERNAL1.name, quality="normal"}, min=1 } ---@type LogisticFilter
local SIG_LIST_IDXF  = { value={type="virtual", name=SIG_LIST_IDX.name, quality="normal"}, min=0 } ---@type LogisticFilter

local ARITH_DELAY = { ---@type ArithmeticCombinatorParameters
	first_signal=SIG_EACH, second_constant=0, operation="+",
	output_signal=SIG_EACH
}
local ARITH_R_MINUS_G = { ---@type ArithmeticCombinatorParameters
	first_signal=SIG_EACH, second_signal=SIG_EACH, operation="-",
	first_signal_networks=netR, second_signal_networks=netG,
	output_signal=SIG_EACH
}

-- pass along each positive signal from platform on R
-- if check signal (INFO) > 0 (on Green)
---@type DeciderCombinatorParameters
local DATA_DC_PARAMS = {conditions={
	{first_signal=SIG_EACH, comparator=">", constant=0, first_signal_networks=netR},
	{first_signal=SIG_INFO, comparator=">", constant=0, first_signal_networks=netG, compare_type="and"}
},outputs={
	{signal=SIG_EACH, copy_count_from_input=true, networks=netR}
}}

-- STAT_DC_PARAMS can't filter negative O out without messing up info/idx/pulse signals
---@type DeciderCombinatorParameters
local STAT_DELAY_AC_PARAMS = {conditions={
	{first_signal=SIG_EACH, comparator=">"},
},outputs={
	{signal=SIG_EACH, copy_count_from_input=true},
}}
-- always output status
---@type DeciderCombinatorParameters
local STAT_DC_PARAMS = {conditions={
	{first_signal=SIG_ANYTHING, comparator="!=", constant=0},
},outputs={
	{signal=SIG_EVERYTHING, copy_count_from_input=true, networks=netR},
	{signal=SIG_INFO, copy_count_from_input=true, networks=netG},
	{signal=SIG_LIST_IDX, copy_count_from_input=true, networks=netG},
	{signal=SIG_SWITCH_PULSE, copy_count_from_input=true, networks=netG},
}}

---@type DeciderCombinatorParameters
local PULSE_DC_PARAMS = {conditions={
	{first_signal=SIG_INTERNAL1, comparator="!=", second_signal=SIG_INTERNAL1,
	 first_signal_networks=netR, second_signal_networks=netG},
},outputs={
	{signal=SIG_SWITCH_PULSE, copy_count_from_input=false, constant=1}
}}

-- If allowing interplanetary comms, raw read modes always work
-- (note that requests still depend on which planet is being currently orbited)
-- still keep check combinator when unchecked to output info signal, and so other code is simpler
---@type DeciderCombinatorParameters
local UNCHECKED_DC_PARAMS = {conditions={
	{first_signal=SIG_ANYTHING, comparator="!=", constant=0, first_signal_networks=netR}
}, outputs={
	{signal=SIG_INFO, copy_count_from_input=false, constant=1}
}}
-- radar on ground: check platform planet directly
-- could also add one loc CC per planet like with platform
---@type DeciderCombinatorParameters
local CHECK_DC_ON_PLANET_PARAMS = {conditions={
	{first_signal={type="space-location", name=nil}, comparator="=", constant=3, first_signal_networks=netR}
}, outputs={
	{signal=SIG_INFO, copy_count_from_input=false, constant=1}
}}
-- radar on platform: check platform location against other platform
-- loc contains only planet signals, so this allows connecting to other platforms in same orbit
-- but not to anything but itself while in connection
---@type DeciderCombinatorParameters
local CHECK_DC_IN_SPACE_PARAMS = {conditions={
	{first_signal=SIG_ORBIT_ID, comparator="<", constant=0, first_signal_networks=netR},
	{first_signal=SIG_ORBIT_ID, comparator="=", second_signal=SIG_ORBIT_ID,
		first_signal_networks=netR, second_signal_networks=netG, compare_type="and"},
	{first_signal=SIG_PLAT_ID, comparator="=", second_signal=SIG_PLAT_ID,
		first_signal_networks=netR, second_signal_networks=netG, compare_type="or"},
}, outputs={
	{signal=SIG_INFO, copy_count_from_input=false, constant=1}
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
	dyn = "circuit_red",
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
local function clear_hidden_circ(data)
	if data.hidden_circ then
		for _,v in pairs(data.hidden_circ) do
			v.destroy()
		end
		data.hidden_circ = nil
	end
end

---@param id unit_number
function M.delete_radar(id)
	local data = storage.radars[id]
	if data then
		clear_hidden_circ(data)
		
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
	local S = data.S
	local read_mode = S.read_mode
	local circ = data.hidden_circ
	
	-- reconfigure circuits
	if not circ or reconfig then
		local base_x = entity.position.x - 1.5
		local base_y = entity.position.y -- - 2.5
		
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
		
		circ = data.hidden_circ
		if not circ then
			circ = {}
			data.hidden_circ = circ
		end
		
		local allow_unchecked = ALLOW_INTERPL and read_mode == "raw"
		local radar_planet = radar_surf.planet -- nil if radar placed on space platform
		
		-- Non-status modes read signals only if platform is in orbit of radar via a planet check in combinator
		---@type DeciderCombinatorParameters
		local params_check
		if allow_unchecked then
			params_check = UNCHECKED_DC_PARAMS
		elseif radar_planet then
			params_check = table.deepcopy(CHECK_DC_ON_PLANET_PARAMS)
			params_check.conditions[1].first_signal.name = radar_planet.name
		else
			params_check = CHECK_DC_IN_SPACE_PARAMS
		end
		
		local radarW = entity.get_wire_connectors(true)
		
		---@param params DeciderCombinatorParameters|ArithmeticCombinatorParameters?
		---@param config CircRG|"circuit_red"|"circuit_green"|boolean?
		---@return LuaWireConnector[]?
		local function combinator(ty, x,y, name, params, config, inR,inG)
			local comb = circ[name]
			if not config then
				if comb then
					comb.destroy()
					circ[name] = nil
				end
				return nil
			else
				if not comb then
					comb = radar_surf.create_entity{ ---@diagnostic disable-line
						name="hexcoder_radar_uplink-"..ty, force=entity.force,
						position={base_x + x*0.75, base_y + y}, snap_to_grid=false,
						direction=defines.direction.south
					} ---@cast comb -nil
					comb.destructible = false
					comb.combinator_description = name
					
					circ[name] = comb
				end
				
				if params then
					local ctrl = comb.get_or_create_control_behavior() --[[@as LuaDeciderCombinatorControlBehavior|LuaArithmeticCombinatorControlBehavior]]
					ctrl.parameters = params
				end
				
				local conns = comb.get_wire_connectors(true)
				for _,c in pairs(conns) do
					c.disconnect_all(HIDDEN)
				end
				
				if inR then conns[W_inR].connect_to(inR, false, HIDDEN) end
				if inG then conns[W_inG].connect_to(inG, false, HIDDEN) end
				
				if type(config) == "table" then
					if config.R then conns[W_outR].connect_to(radarW[W_circR], false, HIDDEN) end
					if config.G then conns[W_outG].connect_to(radarW[W_circG], false, HIDDEN) end
				elseif type(config) == "string" then
					if config == "circuit_red" then conns[W_outR].connect_to(radarW[W_circR], false, HIDDEN) end
					if config == "circuit_green" then conns[W_outG].connect_to(radarW[W_circG], false, HIDDEN) end
				end
				
				return conns
			end
		end
		
		-- planet check DC
		local readRG = S.read ---@cast readRG -nil
		local chk = combinator("dc", 0,-1, "dcCheck", params_check, true) ---@cast chk -nil
		
		-- Delay ACs to match check, or compute unfulfilled requests
		local req_params = read_mode == "std" and ARITH_R_MINUS_G or ARITH_DELAY
		local delaySta = combinator("dc",1, -1, "acSta", STAT_DELAY_AC_PARAMS, readRG.Sta ~= nil) ---@cast delaySta -nil
		local delayReq = combinator("ac",2, -1, "acReq",  req_params, readRG.Req ~= nil) ---@cast delayReq -nil
		local delayOtw = combinator("ac",3, -1, "acOtw", ARITH_DELAY, readRG.Otw ~= nil)
		local delayInv = combinator("ac",4, -1, "acInv", ARITH_DELAY, readRG.Inv ~= nil)
		
		-- Output DCs
		local chkG = chk[W_outG]
		combinator("dc",0, 1, "dcSta", STAT_DC_PARAMS, readRG.Sta, delaySta and delaySta[W_outR], chkG)
		combinator("dc",1, 1, "dcReq", DATA_DC_PARAMS, readRG.Req, delayReq and delayReq[W_outR], chkG)
		combinator("dc",2, 1, "dcOtw", DATA_DC_PARAMS, readRG.Otw, delayOtw and delayOtw[W_outR], chkG)
		combinator("dc",3, 1, "dcInv", DATA_DC_PARAMS, readRG.Inv, delayInv and delayInv[W_outR], chkG)
		
		-- Pulse from CC section toggle + CC section for outputting selected index
		local cc =      combinator("cc", -1,-2.5, "ccPulse", nil, true) ---@cast cc -nil
		local acPulse = combinator("ac", -1,  -1, "acPulse", ARITH_DELAY, true, cc[W_circR]) ---@cast acPulse -nil
		local dcPulse = combinator("dc", -1,   1, "dcPulse", PULSE_DC_PARAMS, true, acPulse[W_outR], cc[W_circG]) ---@cast dcPulse -nil
		
		chkG.connect_to(acPulse[W_outG], false, HIDDEN)
		chkG.connect_to(dcPulse[W_outG], false, HIDDEN)
		
		local ctrl = circ.ccPulse.get_or_create_control_behavior() --[[@as LuaConstantCombinatorControlBehavior]]
		if ctrl.sections_count < 2 then
			ctrl.add_section()
		end
		ctrl.sections[1].filters = { SIG_INTERNAL1F }
		ctrl.sections[2].filters = { SIG_LIST_IDXF }
		
		data.ccPulseSec1 = ctrl.sections[1]
		data.ccPulseSec2 = ctrl.sections[2]
		data.dcCheckR = chk[W_inR]
		data.delayStatR = delaySta[W_inR]
		data.delayStatG = delaySta[W_inG]
		data.delayReqR = delayReq[W_inR]
		data.delayReqG = delayReq[W_inG]
		if read_mode ~= "std" then
			---@cast delayOtw -nil
			---@cast delayInv -nil
			data.delayOtwR = delayOtw[W_inR]
			data.delayInvR = delayInv[W_inR]
		end
		
		local this_plat = entity.surface.platform
		if this_plat and this_plat.valid then
			local this_plat_data = storage.platforms:init_platform(this_plat)
			
			local statCC = this_plat_data.stat_cc.get_wire_connectors(true)
			chk[W_inG].connect_to(statCC[W_circG], false, HIDDEN)
		end
	end
	
	--game.print("reconnect!")
	
	---- disconnect
	local _circR = W_circR
	
	local dcCheckR    = data.dcCheckR ---@cast dcCheckR -nil
	local delayStatR     = data.delayStatR  ---@cast delayStatR -nil
	local delayStatG     = data.delayStatG  ---@cast delayStatG -nil
	local delayReqR      = data.delayReqR   ---@cast delayReqR -nil
	local delayReqG      = data.delayReqG   ---@cast delayReqG -nil
	local delayOtwR      = nil
	local delayInvR      = nil
	
	dcCheckR.disconnect_all(HIDDEN)
	delayStatR .disconnect_all(HIDDEN)
	delayStatG .disconnect_all(HIDDEN)
	delayReqR  .disconnect_all(HIDDEN)
	delayReqG  .disconnect_all(HIDDEN)
	if read_mode ~= "std" then
		delayOtwR = data.delayOtwR  ---@cast delayOtwR -nil
		delayInvR = data.delayInvR  ---@cast delayInvR -nil
		delayOtwR.disconnect_all(HIDDEN)
		delayInvR.disconnect_all(HIDDEN)
	end
	
	local sec1 = data.ccPulseSec1 ---@cast sec1 -nil
	local sec2 = data.ccPulseSec2 ---@cast sec2 -nil
	
	-- trigger switch pulse
	sec1.active = not sec1.active
	
	local plat = S.selected_platform
	
	-- set sel_idx on CC
	-- 0 if platform not found to enable easy iteration
	local filters = sec2.filters
	filters[1].min = plat and S.dyn and data.sel_idx or 0
	sec2.filters = filters
	
	---- connect if powered and platform selected
	local working = data.status == STATUS_WORKING -- powered and not frozen
	if working and plat then
		
		local plStat = plat.stat_cc.get_wire_connectors(true)[_circR]
		dcCheckR.connect_to(plStat, false, HIDDEN)
		delayStatR.connect_to(plStat, false, HIDDEN)
		
		local plReq = plat.req_cc.get_wire_connectors(true)
		local plOtw = plat.otw_cc.get_wire_connectors(true)
		
		if read_mode == "std" then
			delayReqR.connect_to(plReq[_circR], false, HIDDEN)
			delayReqG.connect_to(plOtw[W_circG], false, HIDDEN) -- plOtw G connected to pc G
		else
			local plInv = plat.inv_pc.get_wire_connectors(true)
			
			delayReqR.connect_to(plReq[_circR], false, HIDDEN)
			delayOtwR.connect_to(plOtw[_circR], false, HIDDEN) ---@diagnostic disable-line
			delayInvR.connect_to(plInv[_circR], false, HIDDEN) ---@diagnostic disable-line
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
		clear_hidden_circ(data)
		storage.poll_dyn_select:try_remove(data)
	elseif data.S.mode == "platforms" then
		refresh_radar_platform_mode(entity, data, not sel_changed_only)
	end
	
	radar_channels.update_radar_channel(data)
	
	storage.radars[id] = data
	
	if DEBUG then game.print("after refresh_radar: ".. serpent.line({
			--data.S,
			game.tick,
			data.sel_idx, data.S.selected_platform and data.S.selected_platform.name
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
	local wire = defines.wire_connector_id[S.dyn]
	
	if wire then
		-- list index has priority to enable easy iteration even if dynamic select wire is same as output wire
		local idx = entity.get_signal(SIG_LIST_IDX, wire)
		if idx > 0 then
			local list = M.get_platform_list(data)
			
			local plat_data = list[idx]
			return plat_data, idx
		end
		
		local id = entity.get_signal(SIG_PLAT_ID, wire)
		if id > 0 then
			local plat_data = storage.platforms[id]
			return plat_data
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
	if new_sel == data.S.selected_platform and idx == data.sel_idx then
		return
	end
	
	data.S.selected_platform = new_sel
	data.sel_idx = idx -- keep indx even if platform not found for change detect
	
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
			M.refresh_radar(data, true)
		end
	end
end

function M.refresh_all_radars()
	for _,data in pairs(storage.radars) do
		M.refresh_radar(data)
	end
end

return M