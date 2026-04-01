---@class RadarSettings
---@field mode string
---@field read_mode? string
---@field read? table<string, boolean[]>
---@field selected_platform? platform_index
---@field selected_channel? channel_id

---@class RadarData
---@field id unit_number
---@field entity LuaEntity
---@field status defines.entity_status
---@field S RadarSettings
---@field dcs? table<string, LuaEntity>

---@class PlatformData
---@field platform LuaSpacePlatform
---@field readers table<string, LuaEntity>
---@field _prev_conn LuaSpaceConnectionPrototype?
---@field _prev_progress number?

local util = require("util")
local radar_channels = require("script.radar_channels")

local M = {}

---@param ghost LuaEntity|BlueprintEntity
---@param settings RadarSettings
function M.set_tags(ghost, settings)
	local tags = ghost.tags or {}
	tags["hexcoder_radar_uplink"] = settings
	ghost.tags = tags
end
---@param ghost LuaEntity|BlueprintEntity
---@param entity_id unit_number
---@return boolean
function M.settings_to_tags(ghost, entity_id)
	local data = storage.radars[entity_id]
	if data then
		-- storing selected_channel does not work if channel is deleted afterwards or blueprint is pasted in other savegame!
		-- avoid nonsensical channel selection
		-- TODO: return channels to be by-name and update radars on channel rename?
		--       or store channel name for blueprint etc. and do lookup / lazy create channels on tags->settings
		--       but in then technically is_interplanetary setting would have to be stored too
		local settings = util.table.deepcopy(data.S)
		settings.selected_channel = nil
		M.set_tags(ghost, settings)
		return true
	end
	return false
end

---@param data PlatformData
function update_platform_status(data)
	local plat = data.platform
	
	local signals = {}
	-- platform index
	table.insert(signals, {value={type="virtual", name="signal-P", quality="normal"}, min=plat.index})
	
	-- signal space location that platform is orbiting
	if plat.space_location then
		table.insert(signals, {value={type="space-location", name=plat.space_location.name, quality="normal"}, min=1})
		
		storage.polling_platforms[data.platform.index] = nil
	-- signal space connection platform travelling
	-- since space connections are not supported as signals, output from/to space locations as signals with -1/-2 value
	-- dont do 1/2 like platform hub, due to conflict with space_location, avoid using 2/3 to allow nauvis>0 as condition (use nauvis<0 to check if platform is leaving or arriving)
	elseif plat.space_connection then
		local conn = plat.space_connection ---@cast conn -nil
		local from = conn.from
		local to   = conn.to
		local speed = plat.speed
		local progress = plat.distance
		--local reverse = speed and speed < 0.0 -- speed is never reported negative
		local sched = plat.schedule
		local sched_targ = sched and sched.records[sched.current].station
		
		local reverse = nil
		
		-- report travel direction based on prev and current progress
		if data._prev_conn == conn then
			reverse = progress < data._prev_progress
		end
		data._prev_conn = conn
		data._prev_progress = progress
		
		--game.print(" > delta: ".. delta .." speed: ".. _speed .."reported: ".. speed .." fac: ".. (_speed / speed), p)
		
		table.insert(signals, {value={type="space-location", name=sched_targ, quality="normal"}, min=-10})
		
		if speed then
			-- speed is per tick
			speed = round(speed * 60.0)
			table.insert(signals, {value={type="virtual", name="signal-V", quality="normal"}, min=speed})
		end
		
		-- Only report connection and progress/dist when direction can be safely determined (don't output for one update tick)
		if reverse ~= nil then
			if reverse then
				from = conn.to
				to   = conn.from
				progress = 1.0 - progress
			end
			
			table.insert(signals, {value={type="space-location", name=from.name, quality="normal"}, min=-1})
			table.insert(signals, {value={type="space-location", name=  to.name, quality="normal"}, min=-2})
			
			if progress then
				-- distance is in [0,1]
				local percent = round(progress * 100.0)
				local dist_km = round(progress * conn.length)
				table.insert(signals, {value={type="virtual", name="signal-T", quality="normal"}, min=percent})
				table.insert(signals, {value={type="virtual", name="signal-D", quality="normal"}, min=dist_km})
			end
		end
		
		-- in transit, update in real time
		storage.polling_platforms[data.platform.index] = data
	end
	
	local ctrl = data.readers.stat_raw.get_control_behavior() --[[@as LuaConstantCombinatorControlBehavior]]
	ctrl.sections[1].filters = signals
end
---@param data PlatformData
function update_platform_requests_at_planet(data)
	local plat = data.platform
	
	local signals = {} -- temporary table of signals, could avoid this via LuaLogisticSection.set_slot, but may be slower due to more api calls(?)
	table.insert(signals, { value={ type="virtual", name="signal-info", quality="normal" }, min=1 })
	
	-- Platform hub logistic points, for hubs we seem to always have 2: { requester, passive_provider }
	local logi = plat.hub.get_logistic_point()[1]
	if logi.filters then
		--game.print(">> filters: ")
		-- filters are already compiled (all requests for one item summed) and filtered by import_from planet (unlike raw sections)
		for _, fil in ipairs(logi.filters) do
			--game.print(" > ".. serpent.line(fil))
			-- we can ignore comparator since only =quality setting can have min (others only apply max count which does not result in requests, but the platform dropping items) 
			if fil.count > 0 then
				table.insert(signals, {
					value = { type="item", name=fil.name, quality=fil.quality },
					min = fil.count
				})
			end
		end
	end
	
	local ctrl = data.readers.req_raw.get_control_behavior() --[[@as LuaConstantCombinatorControlBehavior]]
	ctrl.sections[1].filters = signals
end
---@param plat LuaSpacePlatform
function update_platform_pod_deliveries(plat)
	local data = storage.platforms[plat.index]
	if not data then return end
	
	-- Platform hub logistic points, for hubs we have 2: { requester, passive_provider }
	local logi = plat.hub.get_logistic_point()[1] -- access directly to avoid iteration
	
	local signals = {}
	for _, item in ipairs(logi.targeted_items_deliver) do
		if item.count > 0 then
			table.insert(signals, {
				value = { type="item", name=item.name, quality=item.quality },
				min = item.count
			})
		end
	end
	
	local ctrl = data.readers.otw_raw.get_control_behavior() --[[@as LuaConstantCombinatorControlBehavior]]
	ctrl.sections[1].filters = signals -- could avoid
end

script.on_event(defines.events.on_space_platform_changed_state, function (event)
	--game.print("on_space_platform_changed_state: platf ".. event.platform.index .." new_state: ".. serpent.line(event.platform.state))
	
	local data = storage.platforms[event.platform.index]
	if data then
		update_platform_status(data)
		
		if event.platform.state == defines.space_platform_state.waiting_at_station then
			update_platform_requests_at_planet(data)
		end
	end
end)
script.on_event(defines.events.on_entity_logistic_slot_changed, function (event)
	local entity = event.entity
	if entity.type == "space-platform-hub" then
		local platform = entity.surface and entity.surface.platform
		if platform then
			local data = storage.platforms[platform.index]
			if data then
				update_platform_requests_at_planet(data)
			end
		end
	end
end)

-- on_rocket_launch_ordered: the silos are loaded but not yet counted as targeted_items_deliver
-- on this exact tick of on_rocket_launch_ordered the silo contents get added to targeted_items_deliver, and the launch animation can't be cancelled I think
script.on_event(defines.events.on_rocket_launch_ordered, function (event)
	--game.print("on_rocket_launch_ordered : ".. serpent.block(event))
	local pod = event.rocket and event.rocket.attached_cargo_pod
	local hub = pod and pod.cargo_pod_destination.station
	local platform = hub and hub.surface.platform
	-- NOTE: cargo_unit, chest, robot_cargo, item_main all return this same inventory
	--local cargo = pod.get_inventory(defines.inventory.cargo_unit) -- but don't need this because it's likely cheap to just use targeted_items_deliver
	
	if platform then
		update_platform_pod_deliveries(platform)
	end
end)
-- on_rocket_launched: launch animation over (I think rocket silo can be filled again, now pods appear on platform surface, so landing animation)
-- on_cargo_pod_delivered_cargo: pods have landed, and get removed from targeted_items_deliver and added to inventory on this exact tick
script.on_event(defines.events.on_cargo_pod_delivered_cargo, function (event)
	--game.print("on_cargo_pod_delivered_cargo : ".. serpent.block(event))
	local pod = event.cargo_pod
	local platform = pod and pod.surface and pod.surface.platform -- cargo_pod_destination not set anymore
	--local cargo = pod.get_inventory(defines.inventory.cargo_unit) -- empty already
	
	if platform then
		update_platform_pod_deliveries(platform)
	end
end)

-- there seems to be no event for scheduled_for_deletion, so lets just stay connected until it is deleted
---@param p LuaSpacePlatform
---@return boolean
function M.platform_valid(p)
	-- platforms being built don't have a hub yet
	return (p and p.valid and p.hub and p.hub.valid) or false
end

---@param platform LuaSpacePlatform
---@return PlatformData
function M.init_platform(platform)
	local data = storage.platforms[platform.index]
	if not data then
		local reg_id, index = script.register_on_object_destroyed(platform)
		
		local base_pos = { x=platform.hub.position.x-2, y=platform.hub.position.y }
		local arith_negate = {
			first_constant=0, second_signal={type="virtual", name="signal-each"}, operation="-",
			output_signal={type="virtual", name="signal-each"}
		}
		local arith_identity = {
			first_signal={type="virtual", name="signal-each"}, second_constant=1, operation="*",
			output_signal={type="virtual", name="signal-each"}
		}
		-- contant combinators script can write signals into on events
		local function combinator(type, x,y, descr, arith, input)
			local combinator = platform.surface.create_entity{
				name=type, force=platform.force,
				position={base_pos.x+x, base_pos.y+y}, snap_to_grid=false,
				direction=defines.direction.south
			} ---@cast combinator -nil
			combinator.destructible = false
			combinator.combinator_description = descr
			if arith then
				local ctrl = combinator.get_control_behavior() --[[@as LuaArithmeticCombinatorControlBehavior]]
				ctrl.parameters = arith
			end
			if input then
				local i = input.get_wire_connectors(true)[W.circuit_red]
				local o = combinator.get_wire_connectors(true)[W.combinator_input_red]
				o.connect_to(i, false, HIDDEN)
			end
			return combinator
		end
		local function proxy_container(type, x,y)
			local pc = platform.surface.create_entity{
				name=type, force=platform.force,
				position={base_pos.x+x, base_pos.y+y}, snap_to_grid=false
			} ---@cast pc -nil
			pc.destructible = false
			pc.proxy_target_entity = platform.hub
			pc.proxy_target_inventory = defines.inventory.hub_main
			local ctrl = pc.get_or_create_control_behavior() --[[@as LuaProxyContainerControlBehavior]]
			ctrl.read_contents = true
			return pc
		end
		
		local readers = {}
		readers.stat_raw = combinator("hexcoder_radar_uplink-cc", 0,0, "platform status")
		readers.req_raw = combinator("hexcoder_radar_uplink-cc", 1,0, "platform requests at current planet")
		readers.otw_raw = combinator("hexcoder_radar_uplink-cc", 2,0, "platform targeted_items_deliver ('on the way' via rocket silo cargo pod)")
		-- proxy container that automatically reads platform hub iventory without user needing to use "read contents" option
		readers.inv_raw = proxy_container("hexcoder_radar_uplink-pc", 3,0)
		
		readers.stat = combinator("hexcoder_radar_uplink-ac", 0,2, "platform status, delayed 1 tick", arith_identity, readers.stat_raw)
		readers.req = combinator("hexcoder_radar_uplink-ac", 1,2, "platform requests at current planet, delayed 1 tick", arith_identity, readers.req_raw)
		readers.otw_neg = combinator("hexcoder_radar_uplink-ac", 2,2, "platform on the way, delayed 1 tick", arith_negate, readers.otw_raw)
		readers.inv_neg = combinator("hexcoder_radar_uplink-ac", 3,2, "platform hub inventory negated", arith_negate, readers.inv_raw)
		
		data = {
			platform=platform,
			readers=readers,
		}
		storage.platforms[index] = data
		
		update_platform_status(data)
		update_platform_requests_at_planet(data)
	end
	return data
end
---@param id platform_index
function M.reset_platform(id)
	local data = storage.platforms[id]
	for _,e in pairs(data.readers) do
		e.destroy()
	end
	data.readers = nil
	storage.platforms[id] = nil
end

--[[
	init: call to lazily prepare custom entity settings table, called by gui open or spawing with tags
	refresh: call once settings have been modified in gui, and called at end of init_radar
	         when custom mode selected: spawns custom combinators, wires them up and tracks data in custom tables
			 when comms mode selection: resets: despawns combinators, clears from custom tables
	reset: explicitly reset all custom data
	
	never keep entities with comms mode selection radar table nor have combinators for them spawned
	still allow gui to display and modify settings by letting it remeber return data table via init_radar, which it can pass into refresh
	keep ghost entities separate, do not insert into storage, keep and modify their data in entity.tags, but allow gui to edit it by testing for ghosts in init and refresh
]]

M.radar_defaults = {
	pl_std = {
		Sta = { true, true }, -- R, G
		Req = { true, true },
	},
	pl_raw = {
		Sta = { false, true },
		Req = { false, true },
		Otw = { true, false },
		Inv = { true, false },
	}
}

---@param id unit_number
function M.reset_radar(id)
	local data = storage.radars[id]
	if data then
		if data.dcs then
			for _,v in pairs(data.dcs) do
				v.destroy()
			end
			data.dcs = nil -- handle open in gui case
		end
		storage.radars[id] = nil
		storage.polling_radars[id] = nil
	end
end

---@param id unit_number
---@param entity LuaEntity
---@param data RadarData
local function refresh_platform_radar(id, entity, data)
	local platform = entity.force.platforms[data.S.selected_platform]
	local plat_data = M.platform_valid(platform) and M.init_platform(platform) or nil
	
	local planet_sig = {type="space-location", name=entity.surface.planet.prototype.name}
	---@type DeciderCombinatorParameters[]
	
	-- Status DC just passes along info (1-tick delay one-way signal bridge)
	local params_sta = {conditions={
		{first_signal={type="virtual", name="signal-each"}, constant=0, comparator="!=", first_signal_networks=netR}
	},outputs={
		{signal={type="virtual", name="signal-each"}, copy_count_from_input=true, networks=netR}
	}}
	
	-- Unfulfilled requests or if not allowing interplanetary comms:
	-- Requests, On-the-way, Inventory DCs only pass info if platform is orbiting radar surface
	local params_detail = {conditions={
		{first_signal={type="virtual", name="signal-each"}, constant=0, comparator=">", first_signal_networks=netR},
		{first_signal=planet_sig, constant=0, comparator=">", compare_type="and", first_signal_networks=netG},
	},outputs={
		{signal={type="virtual", name="signal-each"}, copy_count_from_input=true, networks=netR}
	}}
	-- If allowing interplanetary comms:
	-- Requests, On-the-way, Inventory DCs only pass on all info (note that requests still depend on which planet is being orbited)
	local params_detail_interpl = {conditions={
		{first_signal={type="virtual", name="signal-each"}, constant=0, comparator=">", first_signal_networks=netR},
	},outputs={
		{signal={type="virtual", name="signal-each"}, copy_count_from_input=true, networks=netR}
	}}
	
	if storage.settings.allow_interpl and data.S.read_mode == "raw" then
		params_detail = params_detail_interpl
	end
	
	local dc_config = {Sta=params_sta, Req=params_detail, Otw=params_detail, Inv=params_detail}
	
	if not data.dcs then
		data.dcs = {}
		local x = entity.position.x-1.5
		for k,_ in pairs(dc_config) do
			local dc = entity.surface.create_entity{
				name="hexcoder_radar_uplink-dc", force=entity.force,
				position={x, entity.position.y+1}, snap_to_grid=false,
				direction=defines.direction.south
			} ---@cast dc -nil
			dc.destructible = false
			
			data.dcs[k] = dc
			x = x+1
		end
	end
	
	local radar = entity.get_wire_connectors(true)
	local working = data.status == defines.entity_status.working
	
	for k,params in pairs(dc_config) do
		local dc = data.dcs[k]
		
		local ctrl = data.dcs[k].get_control_behavior() --[[@as LuaDeciderCombinatorControlBehavior]]
		ctrl.parameters = params
		
		local rg = working and data.S.read[k]
		local con = dc.get_wire_connectors(true)
		
		con[W.combinator_input_red  ].disconnect_all(HIDDEN)
		con[W.combinator_input_green].disconnect_all(HIDDEN)
		con[W.combinator_output_red  ].disconnect_all(HIDDEN)
		con[W.combinator_output_green].disconnect_all(HIDDEN)
		if rg and rg[1] then con[W.combinator_output_red  ].connect_to(radar[W.circuit_red  ], false, HIDDEN) end
		if rg and rg[2] then con[W.combinator_output_green].connect_to(radar[W.circuit_green], false, HIDDEN) end
	end
	
	local dcStat = data.dcs.Sta.get_wire_connectors(false)
	local dcReq = data.dcs.Req.get_wire_connectors(false)
	local dcOtw = data.dcs.Otw.get_wire_connectors(false)
	local dcInv = data.dcs.Inv.get_wire_connectors(false)
	local connected = false
	
	if plat_data then
		--game.print("reconnect!")
		
		if data.S.read_mode == "std" then
			local rStat = plat_data.readers.stat.get_wire_connectors(true)
			local rReq = plat_data.readers.req.get_wire_connectors(true)
			local rOtw = plat_data.readers.otw_neg.get_wire_connectors(true)
			local rInv = plat_data.readers.inv_neg.get_wire_connectors(true)
			
			-- platform status to platform status on red wire
			dcStat[W.combinator_input_red].connect_to(rStat[W.combinator_output_red], false, HIDDEN)
			
			-- platform raw requests to request on red wire
			-- platform status to requests on green wire for planet check
			dcReq[W.combinator_input_red].connect_to(rReq[W.combinator_output_red], false, HIDDEN)
			dcReq[W.combinator_input_red].connect_to(rOtw[W.combinator_output_red], false, HIDDEN)
			dcReq[W.combinator_input_red].connect_to(rInv[W.combinator_output_red], false, HIDDEN)
			dcReq[W.combinator_input_green].connect_to(rStat[W.combinator_output_green], false, HIDDEN)
		else
			local rStat = plat_data.readers.stat_raw.get_wire_connectors(true)
			local rReq = plat_data.readers.req_raw.get_wire_connectors(true)
			local rOtw = plat_data.readers.otw_raw.get_wire_connectors(true)
			local rInv = plat_data.readers.inv_raw.get_wire_connectors(true)
			
			-- platform status to platform status on red wire
			dcStat[W.combinator_input_red].connect_to(rStat[W.circuit_red], false, HIDDEN)
			dcReq[W.combinator_input_red].connect_to(rReq[W.circuit_red], false, HIDDEN)
			dcOtw[W.combinator_input_red].connect_to(rOtw[W.circuit_red], false, HIDDEN)
			dcInv[W.combinator_input_red].connect_to(rInv[W.circuit_red], false, HIDDEN)
			
			dcReq[W.combinator_input_green].connect_to(rStat[W.circuit_green], false, HIDDEN)
			dcOtw[W.combinator_input_green].connect_to(rStat[W.circuit_green], false, HIDDEN)
			dcInv[W.combinator_input_green].connect_to(rStat[W.circuit_green], false, HIDDEN)
		end
		
		connected = true
	end
	
	storage.polling_radars[id] = (not connected) and data or nil -- poll if not connected yet due to to platform build pending
end

---@param data RadarData
function M.refresh_radar(data)
	local entity = data.entity
	local id = data.id
	game.print("refresh_radar: ".. serpent.block(data))
	
	-- write tags to ghosts on change (ui seems to get a copy, possibly because entity.tags is behind API which copies)
	if entity.type == "entity-ghost" then
		M.set_tags(entity, data.S)
		return
	end
	
	if data.S.mode == "comms" then
		if data.dcs then
			for _,v in pairs(data.dcs) do
				v.destroy()
			end
			data.dcs = nil -- handle open in gui case
		end
		
		if data.S.selected_channel == 1 then -- "[Global]"
			M.reset_radar(id)
		else
			storage.radars[id] = data
			storage.polling_radars[id] = nil
		end
	elseif data.S.mode == "platforms" then
		refresh_platform_radar(id, entity, data)
		storage.radars[id] = data
	end
	
	--game.print("after refresh_radar: ".. serpent.block(data))
end
---@param entity LuaEntity
---@param copy_settings RadarSettings?
---@return RadarData
function M.init_radar(entity, copy_settings)
	local S
	if copy_settings then
		S = util.table.deepcopy(copy_settings)
	elseif entity.tags then -- handle allowing gui from ghost entities
		S = entity.tags["hexcoder_radar_uplink"]
	else
		-- default settings if radar not registered in storage
		-- Vanilla-equivalent global comms mode
		S = { -- settings
			mode = "comms",
			selected_channel = 1, -- "[Global]"
		}
	end ---@cast S RadarSettings
	
	local id = entity.unit_number
	local data = storage.radars[id]
	if not data then
		script.register_on_object_destroyed(entity)
		
		data = {
			id = id,
			entity = entity,
			status = entity.status,
			S = S
		}
	end
	
	M.refresh_radar(data)
	return data
end

function M.refresh_all_custom_radars(data)
	for _,data in pairs(storage.radars) do
		M.refresh_radar(data)
	end
end

function M.poll_radar_power(entity)
	local data = storage.radars[entity.unit_number]
	
	if data and entity.status ~= data.status then
		data.status = entity.status
		
		M.refresh_radar(data)
		radar_channels.update_radar_channel(entity)
	end
end

return M