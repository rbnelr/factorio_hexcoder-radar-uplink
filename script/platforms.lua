--[[ Platforms:
	Lazily create platform data and combinators on init_platform(), delete on on_object_destroyed, currently not deleting if no longer used
	TODO: explain circuits on platform
	
	Platform signals can (almost) be updated without on_tick:
	
	Status:
		on_space_platform_changed_state
		but I add an infrequent polling when travelling as I want real-time progress and speed readouts, but this is fast enough
	
	Raw requests: on_entity_logistic_slot_changed + on_space_platform_changed_state (requests change due to import_from depending on location)
	On the way: on_rocket_launch_ordered + on_cargo_pod_delivered_cargo
	Hub Inventory: no events to react to but circuit signals can be implemented via proxy container!
	Inventory Slots: polling for now, probably can react to cargo bay build and destroy, then just query inventory slots in a single call
	
	-> actually on_entity_logistic_slot_changed does not trigger if a section is toggled, so it's not reliable...
]]

---@class (exact) PlatformData
---@field name string
---@field platform LuaSpacePlatform -- should already be built but could be scheduled_for_deletion
---@field stat_cc LuaEntity
---@field req_cc LuaEntity
---@field otw_cc LuaEntity
---@field inv_pc LuaEntity
---@field _prev_loc LuaSpaceConnectionPrototype|LuaSpaceLocationPrototype?
---@field _prev_progress number?

---@class Platforms
---@field [platform_index] PlatformData
---@field all_sorted PlatformData[]
---@field orbiting table<string, PlatformData[]>
---@field _orbit_id table<string, integer>
local Platforms = {}
Platforms.__index = Platforms

local floor = math.floor
local ceil = math.ceil

local function round(num)
	return num >= 0 and floor(num + 0.5) or ceil(num - 0.5)
end

local W = defines.wire_connector_id
local W_circG = W.circuit_green
local HIDDEN = defines.wire_origin.script

--[[
local SIG_PLAT_ID                = {type="virtual", name="signal-P", quality="normal"} ---@type SignalFilter
local SIG_PLAT_PROGRESS_PERCENT  = {type="virtual", name="signal-T", quality="normal"} ---@type SignalFilter
local SIG_PLAT_PROGRESS_DISTANCE = {type="virtual", name="signal-D", quality="normal"} ---@type SignalFilter
local SIG_PLAT_SPEED             = {type="virtual", name="signal-V", quality="normal"} ---@type SignalFilter
local SIG_PLAT_INV_SLOTS         = {type="virtual", name="signal-S", quality="normal"} ---@type SignalFilter
local SIG_ORBIT_ID               = {type="virtual", name="signal-O", quality="normal"} ---@type SignalFilter
]]
local SIG_PLAT_ID                = "signal-P" ---@type SignalFilter
local SIG_PLAT_PROGRESS_PERCENT  = "signal-T" ---@type SignalFilter
local SIG_PLAT_PROGRESS_DISTANCE = "signal-D" ---@type SignalFilter
local SIG_PLAT_SPEED             = "signal-V" ---@type SignalFilter
local SIG_PLAT_INV_SLOTS         = "signal-S" ---@type SignalFilter
local SIG_ORBIT_ID               = "signal-O" ---@type SignalFilter

---@return Platforms
function Platforms.new()
	local ids = {}
	--for name,val in pairs(prototypes["space-location"]) do
	--	if name ~= "space-location-unknown" then
	--		if ids[name] == nil then
	--			ids[name] = table_size(ids)+1
	--		end
	--	end
	--end
	
	-- only LuaPlanet orbits allow connection (not solar system edge and shattered planet)
	for name,val in pairs(game.planets) do
		if ids[name] == nil then
			ids[name] = table_size(ids)+1
		end
	end

	return setmetatable({ all_sorted={}, orbiting={}, _orbit_id=ids }, Platforms)
end

-- platforms that are not build yet are arkward, as they have no hub etc.
-- there seems to be no event for scheduled_for_deletion, so lets just stay connected until it is deleted
---@param p LuaSpacePlatform?
---@return boolean valid
function Platforms.platform_exists(p)
	-- platforms being built don't have a hub yet
	return (p and p.valid and p.hub and p.hub.valid) or false
end

---@param platform LuaSpacePlatform
---@return PlatformData
function Platforms:init_platform(platform)
	assert(self.platform_exists(platform))
	
	local id = platform.index
	local data = self[id]
	if data then
		return data
	end
	
	local base_pos = platform.hub.position
	
	-- contant combinators script can write signals into on events
	local function combinator(type, x,y, descr)
		local combinator = platform.surface.create_entity{
			name=type, force=platform.force,
			position={base_pos.x+x, base_pos.y+y}, snap_to_grid=false,
			direction=(y >= 0 and defines.direction.south or defines.direction.north)
		} ---@cast combinator -nil
		combinator.destructible = false
		combinator.combinator_description = descr
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
	
	data = {
		name = platform.name,
		platform = platform,
		stat_cc = combinator("hexcoder_radar_uplink-cc", -1,1, "platform status"),
		req_cc  = combinator("hexcoder_radar_uplink-cc", 0,1, "platform requests at current planet"),
		otw_cc  = combinator("hexcoder_radar_uplink-cc", 1,1, "platform targeted_items_deliver ('on the way' via rocket silo cargo pod)"),
		-- proxy container that automatically reads platform hub iventory without user needing to use "read contents" option
		inv_pc  = proxy_container("hexcoder_radar_uplink-pc", 1,0),
	}
	
	-- connect here via green to eliminate one wire connect on radar connection switch
	local otw = data.otw_cc.get_wire_connectors(true)
	local inv = data.inv_pc.get_wire_connectors(true)
	otw[W_circG].connect_to(inv[W_circG], false, HIDDEN)
	
	data.stat_cc.get_control_behavior() --[[@as LuaConstantCombinatorControlBehavior]]
		.add_section() -- section 2 for slots
	
	script.register_on_object_destroyed(platform)
	self[id] = data
	
	self:update_platform_status(platform, data)
	self:update_platform_requests_at_planet(platform, data)
	self:update_platform_deliveries_on_the_way(platform, data)
	self:update_platform_inv_slots(platform, data)
	
	return data
end
---@param id platform_index
function Platforms:delete_platform(id)
	local data = self[id]
	if data then
		data.stat_cc.destroy()
		data.req_cc.destroy()
		data.otw_cc.destroy()
		data.inv_pc.destroy()
		self[id] = nil
	end
	
	self:update_all_platforms_list()
end

function Platforms:update_all_platforms_list()
	local list = {}
	local counter = 1
	-- LuaForce.platforms is not documente to be sorted, but appears to be
	-- let's not bother re-sorting for the moment
	for _, platf in pairs(game.forces.player.platforms) do
		if self.platform_exists(platf) then
			list[counter] = self:init_platform(platf)
			counter = counter+1
		end
	end
	
	self.all_sorted = list
	self.orbiting = {} -- invalidate all orbiting
	
	refresh_all_guis()
end

-- invalidate orbiting platforms, refresh any open guis
---@param planet LuaSpaceLocationPrototype
function Platforms:invalidate_orbiting_platform_list(planet)
	local planet_name = planet.name
	self.orbiting[planet_name] = nil
	
	refresh_all_guis()
end

-- return current orbiting "nearby" plaforms list
-- ground surface has fixed planet
-- space platform is either in orbit with other platforms or on space_location where only itself counts as nearby
---@param surface LuaSurface
---@return PlatformData[]
function Platforms:get_orbiting_platform_list(surface)
	-- LuaPlanet or LuaSpaceLocationPrototype
	local space_loc = surface.planet or surface.platform.space_location
	if space_loc == nil then
		assert(surface.platform ~= nil)
		-- radar not on planet but also not at space loacation
		-- can only connect to itself while on space connection
		local plat_data = self[surface.platform.index]
		return { plat_data }
	end
	
	-- return cached planet list or recreate an invalidated one
	local orbit_name = space_loc.name
	local orbiting = self.orbiting[orbit_name]
	if not orbiting then
		-- if LuaSpaceLocationPrototype try get actual planet
		local planet = space_loc.object_name == "LuaPlanet" and space_loc or game.planets[space_loc.name]
		if planet then
			script.register_on_object_destroyed(planet)
			
			orbiting = {}
			local counter = 1
			for _, platf in pairs(planet.get_space_platforms(game.forces.player)) do
				local data = self[platf.index]
				if data then
					orbiting[counter] = data
					counter = counter+1
				end
			end
		else
			-- solar system edge and shattered planet do not actually have planets!
			
			-- TODO: while it makes sense in universe that solar system edge is a huge space, and that we really reach shattered planet
			--       so it could make sense to not allow platforms to reach each other, it seems inconsitent when looking at the space map
			--       also I want to be able to report the progress of my promethium ships with displays on nauvis, so at least radar relays have to be able to do this
			-- -> So we might want to fallback to our own list tracking here (arrival order), which seems relatively simple
			local plat_data = self[surface.platform.index]
			return { plat_data }
		end
		self.orbiting[orbit_name] = orbiting
	end
	return orbiting
end

---@param plat LuaSpacePlatform
---@param data? PlatformData
function Platforms:update_platform_status(plat, data)
	if not plat.valid then return end
	data = data or self[plat.index]
	if not data then return end
	
	-- TODO: could be sped up via caching!
	
	local stat = {} ---@type LogisticFilter[]
	
	-- platform index
	stat[1] = {value=SIG_PLAT_ID, min=plat.index}
	
	-- space location: report that platform is orbiting
	if plat.space_location then
		data._prev_loc = plat.space_location
		
		local loc_name = plat.space_location.name
		local orbit_id = self._orbit_id[loc_name] or 0
		
		stat[2] = {value={type="space-location", name=loc_name, quality="normal"}, min=3}
		stat[4] = {value=SIG_ORBIT_ID, min=-orbit_id}
		
		--storage.polling_platforms[plat.index] = nil -- stop polling if orbiting
	
	-- space connection: report that platform is travelling
	-- since space connections are not supported as signals, output from/to space locations as signals with 1/2 value like hub in vanilla
	elseif plat.space_connection then
		local conn = plat.space_connection ---@cast conn -nil
		local from = conn.from
		local to   = conn.to
		local speed = plat.speed
		local progress = plat.distance
		--local reverse = speed and speed < 0.0 -- speed is never reported negative
		--local sched = plat.schedule
		--local sched_targ = sched and sched.records[sched.current].station
		
		-- space connection to/from is fixed (forward/backward are the same prototype, like in wiki)
		-- the platform has no direct way of telling the direction of the travel on the current space_connection
		--  speed is positive in flight direction (only negative if pausing thrust, and falling back at 10km/s)
		--  schedule gives the actual target, but current connection is just part of the path, so determining next planet is hard
		--  -> instead choose to simply track compute delta of plat.distance
		
		-- nil = unknown (on first polling tick on connection) TODO: fix? previous planet is possible to know!
		-- TODO: did I intentially not use last_visited_space_location? probably because it's not correct if pausing or manually turning back
		local reverse = nil
		if data._prev_loc == conn then
			reverse = progress < data._prev_progress
		elseif data._prev_loc and data._prev_loc.type == "" then
			reverse = data._prev_loc == from
		end
		data._prev_loc = conn
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
			
			stat[2] = {value={type="space-location", name=from.name, quality="normal"}, min=1}
			stat[3] = {value={type="space-location", name=  to.name, quality="normal"}, min=2}
			
			if progress then
				-- distance is in [0,1]
				local percent = round(progress * 100.0)
				local dist_km = round(progress * conn.length)
				stat[5] = {value=SIG_PLAT_PROGRESS_PERCENT, min=percent}
				stat[6] = {value=SIG_PLAT_PROGRESS_DISTANCE, min=dist_km}
			end
		end
		
		if speed then
			-- speed is km/tick, abs to as -10km/s falling back counts as reversing for us, but nor for game
			-- report speed as always positive, whenever start falling back should see to/from reverse
			speed = round(math.abs(speed) * 60.0)
			stat[7] = {value=SIG_PLAT_SPEED, min=speed}
		end
		
		-- in transit, update in real time
		--storage.polling_platforms[plat.index] = data
	end
	
	-- TODO: cache LuaLogisticSection ?
	-- TODO: add valid check!
	local ctrl2 = data.stat_cc.get_control_behavior() --[[@as LuaConstantCombinatorControlBehavior]]
	ctrl2.sections[1].filters = stat
end

---@param plat LuaSpacePlatform
---@param data? PlatformData
function Platforms:update_platform_inv_slots(plat, data)
	if not plat.valid then return end
	data = data or self[plat.index]
	if not data then return end
	
	local inv = plat.hub.get_inventory(defines.inventory.hub_main)
	local slots = inv and #inv or 0
	
	local ctrl = data.stat_cc.get_control_behavior() --[[@as LuaConstantCombinatorControlBehavior]]
	ctrl.sections[2].set_slot(1, {value=SIG_PLAT_INV_SLOTS, min=slots})
end

---@param plat LuaSpacePlatform
---@param data? PlatformData
function Platforms:update_platform_requests_at_planet(plat, data)
	if not plat.valid then return end
	data = data or self[plat.index]
	if not data then return end
	
	-- TODO: optimization here should be easy:
	-- logi.filters can be cached per planet, and only updated on on_entity_logistic_slot_changed and section toggle?
	-- ughh except any auto-requests changes, did I actually forget those?
	-- I guess not that easy... but could try taking logistics sections and just assigning to CC.sections, format is the same, but max, import_from and quality comparator are ignored?
	-- might actually work, but would have to then manually filter for planets, that that might be an API call, table assignment + then iterate and assign nil if planet_from mismatches?
	-- so yeah, could react to on_entity_logistic_slot_changed and cache everything in one cc with sections split up per planet, don't need to bother deduplicating, then enable/disable sections on platform arrive/leave
	-- poll slowly for logistic section enable/disable, disable the correct sections for the planet (note that user can swap sections without event!)
	-- the auto-requests section probably can also just be copied as a table at a certain polling rate, only if enabled and not empty
	
	local signals = {}
	
	-- disable requests while in transit
	local enable_requests = plat.space_location
	  and plat.state ~= defines.space_platform_state.on_the_path
	  and plat.state ~= defines.space_platform_state.waiting_for_departure
	if enable_requests then
		--table.insert(signals, SIG_INFO_1)
		
		-- Platform hub logistic points, for hubs we seem to always have 2: { requester, passive_provider }
		local logi = plat.hub.get_logistic_point(defines.logistic_member_index.cargo_landing_pad_requester)
		if logi and logi.filters then
			-- filters are already compiled (all requests for one item summed) and filtered by import_from planet (unlike raw sections)
			-- while in transit no filter is applied
			for _, fil in pairs(logi.filters) do
				table.insert(signals, {
					value = { type="item", name=fil.name, quality=fil.quality },
					min = fil.count
				})
				--table.insert(signals, { -- TODO: try assinging fil directly to value, as an optimization?
				--	value = fil,
				--	min = fil.count
				--})
			end
		end
	end
	
	local ctrl = data.req_cc.get_control_behavior() --[[@as LuaConstantCombinatorControlBehavior]]
	ctrl.sections[1].filters = signals
end

---@param plat LuaSpacePlatform
---@param data? PlatformData
function Platforms:update_platform_deliveries_on_the_way(plat, data)
	if not plat.valid then return end
	data = data or self[plat.index]
	if not data then return end
	
	local signals = {}
	
	-- Platform hub logistic points, for hubs we have 2: { requester, passive_provider }
	local logi = plat.hub.get_logistic_point(defines.logistic_member_index.cargo_landing_pad_requester)
	if logi and logi.targeted_items_deliver then
		for _, item in pairs(logi.targeted_items_deliver) do
			if item.count > 0 then
				table.insert(signals, {
					value = { type="item", name=item.name, quality=item.quality },
					min = item.count
				})
			end
		end
	end
	
	local ctrl = data.otw_cc.get_control_behavior() --[[@as LuaConstantCombinatorControlBehavior]]
	ctrl.sections[1].filters = signals -- could avoid
end

---@param data PlatformData
function Platforms:poll_platform(data)
	local plat = data.platform
	if not plat.valid then return end
	
	if plat.space_location then
		self:update_platform_requests_at_planet(plat, data)
	else
		self:update_platform_status(plat, data)
	end
	
	-- update via polling for now, could probabably also react to hub and cargo bay build and destroy events?
	self:update_platform_inv_slots(plat, data)
end

-- this does not seem to get called when a platform gets deleted
-- so I may have to add .valid checks to all platforms as on_object_destroyed is unreliable
-- TODO: 
script.on_event(defines.events.on_space_platform_changed_state, function(event)
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
	
	local platforms = storage.platforms
	local plat = event.platform
	
	if event.old_state == defines.space_platform_state.starter_pack_on_the_way then
		assert(platforms[plat.index] == nil)
		platforms:update_all_platforms_list() -- new platform are rare, this is fine
	end
	
	local data = plat.valid and platforms[plat.index]
	if data then
		local prev_loc = data._prev_loc
		platforms:update_platform_status(plat, data)
		local new_loc = data._prev_loc
		
		-- invalidate orbiting of planet we left or arrived at
		local t1 = prev_loc and prev_loc.type
		local t2 = new_loc and new_loc.type
		if t1 ~= t2 then -- don't count changes like paused -> waiting_at_station
			if t1 == "planet" then
				---@cast prev_loc LuaSpaceLocationPrototype
				platforms:invalidate_orbiting_platform_list(prev_loc)
			elseif t2 == "planet" then
				---@cast new_loc LuaSpaceLocationPrototype
				platforms:invalidate_orbiting_platform_list(new_loc)
			end
		end
		
		platforms:update_platform_requests_at_planet(plat, data)
		
		-- update deliveries as a fallback
		platforms:update_platform_deliveries_on_the_way(plat, data)
	end
end)

-- TODO: this does not actually trigger on player en/disabling logistic groups!
-- TODO: need to test logistics groups
script.on_event(defines.events.on_entity_logistic_slot_changed, function(event)
	local entity = event.entity
	if entity.type == "space-platform-hub" then
		--game.print("on_entity_logistic_slot_changed: ".. serpent.line(event))
		local platform = entity.surface and entity.surface.platform
		if platform then
			storage.platforms:update_platform_requests_at_planet(platform)
		end
	end
end)

-- TODO: it's possible to delete cargo pods from scripts, which makes requests end up stuck
-- could try to react to cargo pod and rocket destroy?

-- on_rocket_launch_ordered: the silos are loaded but not yet counted as targeted_items_deliver
-- on this exact tick of on_rocket_launch_ordered the silo contents get added to targeted_items_deliver, and the launch animation can't be cancelled I think
script.on_event(defines.events.on_rocket_launch_ordered, function(event)
	--game.print("on_rocket_launch_ordered : ".. serpent.block(event))
	local pod = event.rocket and event.rocket.attached_cargo_pod
	if pod then
		local hub = pod and pod.cargo_pod_destination.station
		local platform = hub and hub.surface.platform
		-- NOTE: cargo_unit, chest, robot_cargo, item_main all return this same inventory
		--local cargo = pod.get_inventory(defines.inventory.cargo_unit) -- but don't need this because it's likely cheap to just use targeted_items_deliver
		if platform then
			storage.platforms:update_platform_deliveries_on_the_way(platform)
		end
	end
end)
-- on_rocket_launched: launch animation over (I think rocket silo can be filled again, now pods appear on platform surface, so landing animation)
-- on_cargo_pod_delivered_cargo: pods have landed, and get removed from targeted_items_deliver and added to inventory on this exact tick
script.on_event(defines.events.on_cargo_pod_delivered_cargo, function(event)
	--game.print("on_cargo_pod_delivered_cargo : ".. serpent.block(event))
	local pod = event.cargo_pod
	local platform = pod and pod.surface and pod.surface.platform -- cargo_pod_destination not set anymore
	--local cargo = pod.get_inventory(defines.inventory.cargo_unit) -- empty already
	if platform then
		storage.platforms:update_platform_deliveries_on_the_way(platform)
	end
end)

return Platforms