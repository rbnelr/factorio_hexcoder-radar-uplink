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
---@field poll_idx integer
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
---@returns boolean
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

--[[ Platforms:
	Lazily create platform data and combinators on init_platform(), delete on on_object_destroyed, currently not deleting if no longer used
	TODO: explain circuits on platform
	
	Platform signals can mostly be generated without on_tick:
	
	Status: on_space_platform_changed_state (but on_tick when travelling)
	Raw requests: on_entity_logistic_slot_changed + on_space_platform_changed_state (requests change due to import_from depending on location)
	On the way: on_rocket_launch_ordered + on_cargo_pod_delivered_cargo
	Hub Inventory: no events to react to but circuit signals can be implemented via proxy container!
	
	-> actually on_entity_logistic_slot_changed does not trigger if a section is toggled, so it's not reliable...
]]

---@param data PlatformData
function M.update_platform_status(data)
	local plat = data.platform
	
	local loc = {} ---@type LogisticFilter[]
	local stat = {} ---@type LogisticFilter[]
	
	-- platform index
	table.insert(loc, {value={type="virtual", name="signal-P", quality="normal"}, min=plat.index})
	
	-- signal space location that platform is orbiting
	if plat.space_location then
		table.insert(loc, {value={type="space-location", name=plat.space_location.name, quality="normal"}, min=1})
		
		--storage.polling_platforms[data.platform.index] = nil -- stop polling if orbiting
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
		--local sched_targ = sched and sched.records[sched.current].station
		
		local reverse = nil
		
		-- report travel direction based on prev and current progress
		if data._prev_conn == conn then
			reverse = progress < data._prev_progress
		end
		data._prev_conn = conn
		data._prev_progress = progress
		
		-- this might be a bit too confusing / hard to parse in combinators
		--table.insert(signals, {value={type="space-location", name=sched_targ, quality="normal"}, min=-10})
		
		-- Only report connection and progress/dist when direction can be safely determined (don't output for one update tick)
		if reverse ~= nil then
			if reverse then
				from = conn.to
				to   = conn.from
				progress = 1.0 - progress
			end
			
			table.insert(loc, {value={type="space-location", name=from.name, quality="normal"}, min=-1})
			table.insert(loc, {value={type="space-location", name=  to.name, quality="normal"}, min=-2})
			
			if progress then
				-- distance is in [0,1]
				local percent = round(progress * 100.0)
				local dist_km = round(progress * conn.length)
				table.insert(stat, {value={type="virtual", name="signal-T", quality="normal"}, min=percent})
				table.insert(stat, {value={type="virtual", name="signal-D", quality="normal"}, min=dist_km})
			end
		end
		
		if speed then
			-- speed is per tick
			speed = round(math.abs(speed) * 60.0)
			table.insert(stat, {value={type="virtual", name="signal-V", quality="normal"}, min=speed})
		end
		
		-- in transit, update in real time
		--storage.polling_platforms[data.platform.index] = data
	end
	
	local ctrl = data.readers.loc_cc.get_control_behavior() --[[@as LuaConstantCombinatorControlBehavior]]
	ctrl.sections[1].filters = loc
	
	local ctrl2 = data.readers.stat_cc.get_control_behavior() --[[@as LuaConstantCombinatorControlBehavior]]
	ctrl2.sections[1].filters = stat
end
---@param data PlatformData
function M.update_platform_requests_at_planet(data)
	local plat = data.platform
	
	local signals = {} -- temporary table of signals, could avoid this via LuaLogisticSection.set_slot, but may be slower due to more api calls(?)
	
	-- disable requests while in transit
	local enable_requests = plat.space_location
	  and plat.state ~= defines.space_platform_state.on_the_path
	  and plat.state ~= defines.space_platform_state.waiting_for_departure
	if enable_requests then
		table.insert(signals, { value={ type="virtual", name="signal-info", quality="normal" }, min=1 })
		
		-- Platform hub logistic points, for hubs we seem to always have 2: { requester, passive_provider }
		local logi = plat.hub.get_logistic_point(defines.logistic_member_index.cargo_landing_pad_requester)
		if logi and logi.filters then
			--game.print(">> filters: ")
			-- filters are already compiled (all requests for one item summed) and filtered by import_from planet (unlike raw sections)
			-- while in transit no filter is applied
			for _, fil in ipairs(logi.filters) do
				--game.print(" > ".. serpent.line(fil))
				--if fil.count > 0 then
					table.insert(signals, {
						value = { type="item", name=fil.name, quality=fil.quality },
						min = fil.count
					})
				--end
				--table.insert(signals, { -- TODO: try assinging fil directly to value, as an optimization?
				--	value = fil,
				--	min = fil.count
				--})
			end
		end
	end
	
	local ctrl = data.readers.req_cc.get_control_behavior() --[[@as LuaConstantCombinatorControlBehavior]]
	ctrl.sections[1].filters = signals
end
---@param plat LuaSpacePlatform
function update_platform_pod_deliveries(plat)
	local data = storage.platforms[plat.index]
	if not data then return end
	
	-- Platform hub logistic points, for hubs we have 2: { requester, passive_provider }
	local logi = plat.hub.get_logistic_point(defines.logistic_member_index.cargo_landing_pad_requester)
	
	local signals = {}
	for _, item in ipairs(logi.targeted_items_deliver) do
		if item.count > 0 then
			table.insert(signals, {
				value = { type="item", name=item.name, quality=item.quality },
				min = item.count
			})
		end
	end
	
	local ctrl = data.readers.otw_cc.get_control_behavior() --[[@as LuaConstantCombinatorControlBehavior]]
	ctrl.sections[1].filters = signals -- could avoid
end
---@param data PlatformData
function update_platform_inv_slots(data)
	-- Platform hub logistic points, for hubs we have 2: { requester, passive_provider }
	local inv = data.platform.hub.get_inventory(defines.inventory.hub_main)
	local slots = inv and #inv or 0
	
	local ctrl = data.readers.inv_slots_cc.get_control_behavior() --[[@as LuaConstantCombinatorControlBehavior]]
	ctrl.sections[1].set_slot(1, {
		value = { type="virtual", name="signal-S", quality="normal" },
		min = slots
	})
end

script.on_event(defines.events.on_space_platform_changed_state, function (event)
	--local names = {
	--	[defines.space_platform_state.waiting_for_starter_pack] = "waiting_for_starter_pack",
	--	[defines.space_platform_state.starter_pack_requested] = "starter_pack_requested",
	--	[defines.space_platform_state.starter_pack_on_the_way] = "starter_pack_on_the_way",
	--	[defines.space_platform_state.on_the_path] = "on_the_path",
	--	[defines.space_platform_state.waiting_for_departure] = "waiting_for_departure",
	--	[defines.space_platform_state.no_schedule] = "no_schedule",
	--	[defines.space_platform_state.no_path] = "no_path",
	--	[defines.space_platform_state.waiting_at_station] = "waiting_at_station",
	--	[defines.space_platform_state.paused] = "paused",
	--}
	--game.print("on_space_platform_changed_state: platf ".. event.platform.index .." new_state: ".. serpent.line({ event.platform.state, names[event.platform.state] }))
	
	local data = storage.platforms[event.platform.index]
	if data then
		M.update_platform_status(data)
		M.update_platform_requests_at_planet(data)
	end
end)
-- TODO: this does not actually trigger on player en/disabling logistic groups!
script.on_event(defines.events.on_entity_logistic_slot_changed, function (event)
	local entity = event.entity
	if entity.type == "space-platform-hub" then
		--game.print("on_entity_logistic_slot_changed: ".. serpent.line(event))
		
		local platform = entity.surface and entity.surface.platform
		if platform then
			local data = storage.platforms[platform.index]
			if data then
				M.update_platform_requests_at_planet(data)
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

-- TODO: it's possible to delete cargo pods from scripts, which makes this logic end up wrong
-- could at least try to react to cargo pod destroy etc.

---@param data PlatformData
function M.poll_platform(data)
	if data.platform.space_location then
		M.update_platform_requests_at_planet(data)
	else
		M.update_platform_status(data)
	end
	-- update via polling for now, could probabably also react to hub and cargo bay build and destroy events?
	update_platform_inv_slots(data)
end

-- there seems to be no event for scheduled_for_deletion, so lets just stay connected until it is deleted
---@param p LuaSpacePlatform
---@returns boolean
function M.platform_valid(p)
	-- platforms being built don't have a hub yet
	return (p and p.valid and p.hub and p.hub.valid) or false
end

---@param platform LuaSpacePlatform
---@returns PlatformData
function M.init_platform(platform)
	local data = storage.platforms[platform.index]
	if not data then
		local _, index = script.register_on_object_destroyed(platform)
		
		local base_pos = { x=platform.hub.position.x-2, y=platform.hub.position.y }
		
		local arith_identity = { ---@type ArithmeticCombinatorParameters
			first_signal={type="virtual", name="signal-each"}, second_constant=1, operation="*",
			output_signal={type="virtual", name="signal-each"}
		}
		local arith_RminusG = { ---@type ArithmeticCombinatorParameters
			first_signal={type="virtual", name="signal-each"}, second_signal={type="virtual", name="signal-each"}, operation="-",
			first_signal_networks=netR, second_signal_networks=netG,
			output_signal={type="virtual", name="signal-each"}
		}
		-- contant combinators script can write signals into on events
		local function combinator(type, x,y, descr, arith, input_red, inputs_green)
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
			if input_red then
				local i = input_red.get_wire_connectors(true)[W.circuit_red]
				local o = combinator.get_wire_connectors(true)[W.combinator_input_red]
				o.connect_to(i, false, HIDDEN)
			end
			if inputs_green then
				for _,inp in ipairs(inputs_green) do
					local i = inp.get_wire_connectors(true)[W.circuit_green]
					local o = combinator.get_wire_connectors(true)[W.combinator_input_green]
					o.connect_to(i, false, HIDDEN)
				end
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
		
		-- Split location (orbiting planet or space connection + platform id)
		-- from speed, progress etc. for planet check for radars on platforms to work correctly
		local readers = {}
		readers.loc_cc  = combinator("hexcoder_radar_uplink-cc", 0,0, "platform location")
		readers.stat_cc = combinator("hexcoder_radar_uplink-cc", -1,0, "platform status")
		readers.req_cc  = combinator("hexcoder_radar_uplink-cc", 1,0, "platform requests at current planet")
		readers.otw_cc  = combinator("hexcoder_radar_uplink-cc", 2,0, "platform targeted_items_deliver ('on the way' via rocket silo cargo pod)")
		-- proxy container that automatically reads platform hub iventory without user needing to use "read contents" option
		readers.inv_pc  = proxy_container("hexcoder_radar_uplink-pc", 3,0)
		readers.inv_slots_cc  = combinator("hexcoder_radar_uplink-cc", 4,0, "platform inventory slots")
		
		readers.stat    = combinator("hexcoder_radar_uplink-ac", 0,1.5, "platform status, delay=1", arith_identity, readers.loc_cc, {readers.stat_cc})
		readers.req_raw = combinator("hexcoder_radar_uplink-ac", 1,1.5, "platform requests at current planet, delay=1", arith_identity, readers.req_cc)
		readers.otw_raw = combinator("hexcoder_radar_uplink-ac", 2,1.5, "platform deliveries on the way, delay=1", arith_identity, readers.otw_cc)
		readers.inv_raw = combinator("hexcoder_radar_uplink-ac", 3,1.5, "platform hub inventory negated, delay=1", arith_identity, readers.inv_pc)
		readers.inv_slots_raw = combinator("hexcoder_radar_uplink-ac", 4,1.5, "platform hub inventory slots, delay=1", arith_identity, readers.inv_slots_cc)
		
		readers.req = combinator("hexcoder_radar_uplink-ac", 4,-2, "unfulfilled platform requests", arith_RminusG, readers.req_cc, { readers.otw_cc, readers.inv_pc })
		
		data = {
			platform=platform,
			readers=readers,
		}
		storage.platforms[index] = data
		
		M.update_platform_status(data)
		M.update_platform_requests_at_planet(data)
	end
	return data
end
---@param id platform_index
function M.delete_platform(id)
	local data = storage.platforms[id]
	if data then
		for _,e in pairs(data.readers) do
			e.destroy()
		end
		data.readers = nil
		storage.platforms[id] = nil
	end
end

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

local function add_to_poll_list(data)
	assert(data.poll_idx == nil)
	data.poll_idx = #storage.polling_radars+1
	storage.polling_radars[data.poll_idx] = data
end
local function remove_from_poll_list(data)
	-- delete by swap with last
	local idx = data.poll_idx
	data.poll_idx = nil
	local last = #storage.polling_radars
	storage.polling_radars[idx] = storage.polling_radars[last]
	storage.polling_radars[idx].poll_idx = idx
	storage.polling_radars[last] = nil
end

---@param entity LuaEntity
function M.is_radar(entity)
	return entity.name == "radar" or (entity.type == "entity-ghost" and entity.ghost_name == "radar")
end

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
		InvSlots = { false, false },
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
		
		remove_from_poll_list(data)
	end
end

local SIG_EACH = {type="virtual", name="signal-each"}
local SIG_CHECK = {type="virtual", name="signal-check"}

---@param id unit_number
---@param entity LuaEntity
---@param data RadarData
local function refresh_radar_platform_mode(id, entity, data)
	local platform = entity.force.platforms[data.S.selected_platform]
	local plat_data = data.S.selected_platform and M.init_platform(platform) or nil
	assert((platform ~= nil) == (M.platform_valid(platform) == true))
	
	local radar_surf = entity.surface
	local radar_planet = radar_surf.planet -- nil if radar placed on space platform
	
	local allow_unchecked = storage.settings.allow_interpl and data.S.read_mode == "raw"
	
	-- Status DC just passes along info (1-tick delay one-way signal bridge)
	local params_sta = {conditions={
		{first_signal=SIG_EACH, constant=0, comparator="!=", first_signal_networks=netR}
	},outputs={
		{signal=SIG_EACH, copy_count_from_input=true, networks=netR}
	}}
	local params_detail
	local params_check
	
	if radar_planet then
		-- radar on ground: check platform planet directly
		local planet_sig = {type="space-location", name=radar_planet.name}
		---@type DeciderCombinatorParameters
		params_check = {conditions={
			{first_signal=SIG_EACH, constant=0, comparator=">"}, -- Each RG > 0
			{first_signal=planet_sig, constant=0, comparator=">", first_signal_networks=netR, compare_type="and" }
		},outputs={
			{signal=SIG_CHECK, copy_count_from_input=false, constant=1}
		}}
	else
		-- radar on platform: check platform planet via comparison
		---@type DeciderCombinatorParameters
		params_check = {conditions={
			{first_signal=SIG_EACH, constant=0, comparator=">"}, -- Each RG > 0
			{first_signal=SIG_EACH, second_signal=SIG_EACH, comparator="=",
			first_signal_networks=netR, second_signal_networks=netG, compare_type="and" } -- Each R == Each G
		},outputs={
			{signal=SIG_CHECK, copy_count_from_input=false, constant=1}
		}}
	end
	
	if allow_unchecked then
		-- If allowing interplanetary comms, raw read modes always work
		-- (note that requests still depend on which planet is being currently orbited)
		---@type DeciderCombinatorParameters
		params_detail = {conditions={
			{first_signal=SIG_EACH, constant=0, comparator=">", first_signal_networks=netR}
		},outputs={
			{signal=SIG_EACH, copy_count_from_input=true, networks=netR}
		}}
	else
		-- Non-status modes read signals only if platform is in orbit of radar via a planet check in combinator
		---@type DeciderCombinatorParameters
		params_detail = {conditions={
			{first_signal=SIG_EACH, constant=0, comparator=">", first_signal_networks=netR},
			{first_signal=SIG_CHECK, constant=0, comparator=">", first_signal_networks=netG, compare_type="and"}
		},outputs={
			{signal=SIG_EACH, copy_count_from_input=true, networks=netR}
		}}
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
	
	local dcs = data.dcs
	if not dcs then
		dcs = {}
		dcs.Sta = make_combinator(0,1, "platform status")
		dcs.Req = make_combinator(.75,1, "platform req")
		dcs.Otw = make_combinator(1.5,1, "platform otw")
		dcs.Inv = make_combinator(2.25,1, "platform inv")
		dcs.InvSlots = make_combinator(3,1, "platform slots")
		dcs.Check = make_combinator(3,-1, "platform location check")
	end
	
	local rad = entity.get_wire_connectors(true)
	local working = data.status == defines.entity_status.working -- powered and not frozen
	
	local function config_combinator(dc, params, rg)
		local ctrl = dc.get_control_behavior() --[[@as LuaDeciderCombinatorControlBehavior]]
		ctrl.parameters = params
		
		rg = working and rg
		local con = dc.get_wire_connectors(true)
		
		con[W.combinator_input_red  ].disconnect_all(HIDDEN)
		con[W.combinator_input_green].disconnect_all(HIDDEN)
		con[W.combinator_output_red  ].disconnect_all(HIDDEN)
		con[W.combinator_output_green].disconnect_all(HIDDEN)
		if rg and rg[1] then con[W.combinator_output_red  ].connect_to(rad[W.circuit_red  ], false, HIDDEN) end
		if rg and rg[2] then con[W.combinator_output_green].connect_to(rad[W.circuit_green], false, HIDDEN) end
	end
	
	config_combinator(dcs.Sta, params_sta, data.S.read.Sta)
	config_combinator(dcs.Req, params_detail, data.S.read.Req)
	config_combinator(dcs.Otw, params_detail, data.S.read.Otw)
	config_combinator(dcs.Inv, params_detail, data.S.read.Inv)
	config_combinator(dcs.InvSlots, params_detail, data.S.read.InvSlots)
	config_combinator(dcs.Check, params_check)
	
	-- connect DCs to platform if platform initialized
	local dcStat = dcs.Sta.get_wire_connectors(false)
	local dcReq = dcs.Req.get_wire_connectors(false)
	local dcOtw = dcs.Otw.get_wire_connectors(false)
	local dcInv = dcs.Inv.get_wire_connectors(false)
	local dcInvSlots = dcs.InvSlots.get_wire_connectors(false)
	local dcCheck = dcs.Check.get_wire_connectors(false)
	--local connected = false
	
	data.dcs = dcs
	
	if plat_data then
		--game.print("reconnect!")
		
		local dcCheckG = dcCheck[W.combinator_output_green]
		
		local plLocCC = plat_data.readers.loc_cc.get_wire_connectors(true)
		local plStat = plat_data.readers.stat.get_wire_connectors(true)
		
		local this_plat = radar_surf.platform and M.platform_valid(radar_surf.platform) and M.init_platform(radar_surf.platform) or nil
		
		dcCheck[W.combinator_input_red].connect_to(plLocCC[W.circuit_red], false, HIDDEN)
		if this_plat then
			local pl2LocCC = this_plat.readers.loc_cc.get_wire_connectors(true)
			dcCheck[W.combinator_input_green].connect_to(pl2LocCC[W.circuit_green], false, HIDDEN)
		end
		
		dcStat[W.combinator_input_red].connect_to(plStat[W.combinator_output_red], false, HIDDEN)
		
		if data.S.read_mode == "std" then
			local plReq = plat_data.readers.req.get_wire_connectors(true)
			
			dcReq[W.combinator_input_red].connect_to(plReq[W.combinator_output_red], false, HIDDEN)
			dcReq[W.combinator_input_green].connect_to(dcCheckG, false, HIDDEN)
		else
			local plReq = plat_data.readers.req_raw.get_wire_connectors(true)
			local plOtw = plat_data.readers.otw_raw.get_wire_connectors(true)
			local plInv = plat_data.readers.inv_raw.get_wire_connectors(true)
			local plInvSlots = plat_data.readers.inv_slots_raw.get_wire_connectors(true)
			
			dcReq[W.combinator_input_red].connect_to(plReq[W.combinator_output_red], false, HIDDEN)
			dcReq[W.combinator_input_green].connect_to(dcCheckG, false, HIDDEN)
			dcOtw[W.combinator_input_red].connect_to(plOtw[W.combinator_output_red], false, HIDDEN)
			dcOtw[W.combinator_input_green].connect_to(dcCheckG, false, HIDDEN)
			dcInv[W.combinator_input_red].connect_to(plInv[W.combinator_output_red], false, HIDDEN)
			dcInv[W.combinator_input_green].connect_to(dcCheckG, false, HIDDEN)
			dcInvSlots[W.combinator_input_red].connect_to(plInvSlots[W.combinator_output_red], false, HIDDEN)
			dcInvSlots[W.combinator_input_green].connect_to(dcCheckG, false, HIDDEN)
		end
		
		--connected = true
	end
end

---@param data RadarData
function M.refresh_radar(data)
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
		refresh_radar_platform_mode(id, entity, data)
	end
	
	radar_channels.update_radar_channel(data)
	
	storage.radars[id] = data
	--game.print("after refresh_radar: ".. serpent.block(data))
end
---@param entity LuaEntity
---@param copy_settings RadarSettings?
---@returns RadarData
function M.init_radar(entity, copy_settings)
	local id = entity.unit_number
	local data = storage.radars[id]
	if not data then
		local S
		if copy_settings then
			S = util.table.deepcopy(copy_settings)
		else
			local tags = entity.tags and entity.tags["hexcoder_radar_uplink"]
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
			add_to_poll_list(data)
			
			script.register_on_object_destroyed(entity)
		end
	end
	
	M.refresh_radar(data)
	return data
end

---@param data RadarData
function M.poll_radar(data)
	--assert(M.is_radar(data.entity))
	
	local new_status = data.entity.status ---@cast new_status -nil
	if new_status ~= data.status then
		data.status = new_status
		M.refresh_radar(data)
	end
end

function M.refresh_all_custom_radars()
	for _,data in pairs(storage.radars) do
		M.refresh_radar(data)
	end
end

return M