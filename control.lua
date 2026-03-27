--[[
-- TODO: allow access to raw inventory, request and on the way signals (should be expose these with 1 or 2 tick delay?)
  -> user would likely want to compute them themselves, so either they add exactly one tick more and 1 tick is ideal, or they add more delay anyway
  -> connect to 1tick is ideal, minimal hidden circuits, minimal delay, make the gui allow either status + requests at 2 tick or the raw versions at 1 tick, then put a warning somewhere

-- TODO: consider how to delete channels
-- TODO: GUI to actually add and select custom channels

-- TODO: radars can currently send data to other radars without power, how to fix?
-- Seems to be impossible without polling each radar, maybe just don't care?
-- Or could alternate and update each rader every 60th tick, then dis or reconnect to hub, this might be acceptable

-- TODO: undo/redo? seems hard
-- TODO: blueprint over? hacky workaround but maybe not that hard?
-- TODO: copy paste? not really possible to to properly (with visual feedback?); but could fake using key events? not worth it if blueprint over works I think

-- TODO: remove glib dependency?
--]]

---@class player_index : integer
---@class unit_number : integer
---@class platform_index : integer
---@class surface_index : integer

---@class ModStorage
---@field open_guis table<player_index, OpenGui>
---@field radars table<unit_number, RadarData>
---@field platforms table<platform_index, PlatformData>
---@field polling_radars table<unit_number, RadarData>
---@field polling_platforms table<platform_index, PlatformData>
---@field chsurfaces table<surface_index, SurfaceChannels>

---@type ModStorage
storage = storage

---@class SurfaceChannels
---@field nextpos number
---@field channels table<string, Channel>
---@field hubs LuaEntity[]

---@class Channel
---@field hub LuaEntity
---@field link_hub LuaEntity
---@field is_interplanetary boolean

---@class OpenGui
---@field refs table
---@field data RadarData
---@field drop_down_platforms platform_index[]

---@class RadarSettings
---@field mode string?
---@field read_plat_status boolean
---@field read_plat_statusRG integer
---@field read_plat_requests boolean
---@field read_plat_requestsRG integer
---@field selected_platform platform_index?

---@class RadarData
---@field id unit_number
---@field entity LuaEntity
---@field S RadarSettings
---@field dcs LuaEntity[]?

---@class PlatformData
---@field platform LuaSpacePlatform
---@field readers table<string, LuaEntity>
---@field _prev_conn LuaSpaceConnectionPrototype?
---@field _prev_progress number?

local util = require("util")
local glib = require("__glib__/glib")
local default_frame = require("__glib__/examples/default_frame")

local handlers = {}

local function round(num)
	return num >= 0 and math.floor(num + 0.5) or math.ceil(num - 0.5)
end
local netR = {red=true, green=false}
local netG = {red=false, green=true}
local W = defines.wire_connector_id
local HIDDEN = defines.wire_origin.player -- defines.wire_origin.script

-- simply re-link all link hubs of this channel on all registered surfaces
-- could be optimized by using actual linked list logic, list of surfaces with radars will be small
---@param channel_name string
local function update_channel_surface_links(channel_name)
	--game.print(">> update_channel_surface_links: ".. channel_name)
	
	local prevR = nil
	local prevG = nil
	for _, surfch in pairs(storage.chsurfaces) do
		local channel = surfch.channels[channel_name]
		if channel then
			local h = channel.hub.get_wire_connectors(true)
			local l = channel.link_hub.get_wire_connectors(true)
			
			local lR = l[W.circuit_red  ]
			local lG = l[W.circuit_green]
			
			lR.disconnect_all(HIDDEN)
			lG.disconnect_all(HIDDEN)
			
			if channel.is_interplanetary then
				lR.connect_to(h[W.circuit_red  ], false, HIDDEN)
				lG.connect_to(h[W.circuit_green], false, HIDDEN)
			end
			
			if prevR then ---@cast prevG -nil
				lR.connect_to(prevR, false, HIDDEN)
				lG.connect_to(prevG, false, HIDDEN)
			end
			prevR = lR
			prevG = lG
		end
	end
end
---@param channel Channel
local function set_is_interplanetary(channel)
	local a = channel.hub.get_wire_connectors(true)
	local b = channel.link_hub.get_wire_connectors(true)
	if channel.is_interplanetary then
		a[W.circuit_red  ].connect_to(b[W.circuit_red  ], false, HIDDEN)
		a[W.circuit_green].connect_to(b[W.circuit_green], false, HIDDEN)
	else
		a[W.circuit_red  ].disconnect_from(b[W.circuit_red  ], HIDDEN)
		a[W.circuit_green].disconnect_from(b[W.circuit_green], HIDDEN)
	end
end

---@param surface LuaSurface
local function init_surf_data(surface)
	-- lazily create surface data
	local surfch = storage.chsurfaces[surface.index]
	if not surfch then
		surfch = { nextpos=0, channels={}, hubs={} }
		storage.chsurfaces[surface.index] = surfch
	end
	return surfch
end
-- init channel for surface, if the same channel also gets created on other surface, their link_hub will be connected
---@param surfch SurfaceChannels
---@param channel_name string
---@param surface LuaSurface
local function init_channel(surfch, channel_name, surface)
	-- lazily create channel data
	local channel = surfch.channels[channel_name]
	if not channel then
		-- Hub to directly connect all radars that have this channel selected to
		-- Switching radar channel is now O(1)!
		-- If mod deinstalled, this hub disappears and automatically removes all hidden radar wires (and vanilla links reappear)!
		local hub = surface.create_entity{
			name="hexcoder_radar_uplink-cc", force="player",
			position={surfch.nextpos+0.5, 0.5}, snap_to_grid=false
		} ---@cast hub -nil
		hub.destructible = false
		hub.combinator_description = "Radar signal radar hub :".. surface.name ..":".. channel_name
		
		-- Interplanetary link hub, which connect connect in chain to same hub on all other surfaces
		-- Switching a channel interplanetary status is now O(1)!
		-- update_channel_surface_links() now only needs to be called on surface create/destroy!
		-- (If single hub existed, update_channel_surface_links() would need to be called on interplanetary toggle, and may have to iterate countless radar wires to find ones to remove)
		local link_hub = surface.create_entity{
			name="hexcoder_radar_uplink-cc", force="player",
			position={surfch.nextpos+0.5, 1.5}, snap_to_grid=false
		} ---@cast link_hub -nil
		link_hub.destructible = false
		link_hub.combinator_description = "Radar signal surface hub :".. surface.name ..":".. channel_name
		
		local interplanetary = channel_name ~= "_global"
		
		channel = { hub=hub, link_hub=link_hub, is_interplanetary=interplanetary }
		surfch.channels[channel_name] = channel
		--if debug then
			surfch.nextpos = surfch.nextpos + 1
		--end
		
		update_channel_surface_links(channel_name)
		
		set_is_interplanetary(channel)
	end
	
	return channel
end
---@param surfch SurfaceChannels
---@param channel_name string
local function destroy_channel(surfch, channel_name)
	--game.print(">> destroy_channel: ".. serpent.block({ surfch, channel_name }))
	local channel = surfch.channels[channel_name]
	
	channel.hub.destroy()
	channel.link_hub.destroy()
	
	surfch.channels[channel_name] = nil
	
	-- fix broken link
	update_channel_surface_links(channel_name)
end

---@param surfch SurfaceChannels
local function leave_channel(surfch, old_hub)
	-- delete hubs for channels once channel no longer used by using wires at hub as refcount
	-- alternatively just make user delete old channels via gui?
	-- TODO: test this
	--if old_hub then
	--	local conR = old_hub.get_wire_connectors(true)[R]
	--	if conR.connection_count <= 2 then -- max 2 surface links in chain
	--		if conR.connections[1].target.owner.name == "hexcoder_radar_uplink-cc" and conR.connections[2] and
	--		   conR.connections[2].target.owner.name == "hexcoder_radar_uplink-cc" then
	--			-- connection now useless
	--			local name = surfch.hubs[old_hub.unit_number]
	--			--surfch.hubs[ch_hub.unit_number] = nil
	--			--surfch.channels[name] = nil
	--			--
	--			--old_hub.destroy()
	--			destroy_channel(...)
	--		end
	--	end
	--end
end
---@param entity LuaEntity
---@param channel_name string
---@param surface LuaSurface
local function channel_switch(entity, channel_name, surface)
	--game.print(">> channel_switch: ".. serpent.line({ entity, channel_name, surface }))
	
	-- true: create connector: if no current connections, would otherwise return nil
	local conR = entity.get_wire_connectors(true)[W.circuit_red]
	local conG = entity.get_wire_connectors(true)[W.circuit_green]
	
	local old_hub = nil
	for _, c in ipairs(conR.connections) do
		if c.origin == HIDDEN and (c.target.owner.name == "hexcoder_radar_uplink-cc") then
				--or c.target.owner.name == "radar") then --dbg
			conR.disconnect_from(c.target, HIDDEN)
			old_hub = c.target.owner
		end
	end
	for _, c in ipairs(conG.connections) do
		if c.origin == HIDDEN and (c.target.owner.name == "hexcoder_radar_uplink-cc") then
				--or c.target.owner.name == "radar") then --dbg
			conG.disconnect_from(c.target, HIDDEN)
		end
	end
	--conR.disconnect_all(defines.wire_origin.script) --dbg
	--conG.disconnect_all(defines.wire_origin.script) --dbg
	
	local surfch = init_surf_data(surface)
	
	leave_channel(surfch, old_hub)
	
	if channel_name then
		-- enter channel
		local channel = init_channel(surfch, channel_name, surface)
		
		local cc = channel.hub.get_wire_connectors(true)
		conR.connect_to(cc[W.circuit_red  ], false, HIDDEN)
		conG.connect_to(cc[W.circuit_green], false, HIDDEN)
	end
end
---@param entity LuaEntity
local function update_radar_channel(entity)
	local data = storage.radars[entity.unit_number]
	--game.print(">> update_radar_channel: ".. serpent.block(data))
	
	local channel_name
	if data and data.S.mode ~= nil then
		channel = nil
		--channel_name = "interplanetary1"
	else
		channel_name = "_global"
	end
	
	channel_switch(entity, channel_name, entity.surface)
end

--@param surf_id surface_index
--@param surface LuaSurface
local function _surface_event(surf_id, surface)
	local surfch = storage.chsurfaces[surf_id]
	if surfch then
		-- delete surface data
		for channel_name, _ in pairs(surfch.channels) do
			destroy_channel(surfch, channel_name)
		end
		storage.chsurfaces[surf_id] = nil
	end
	
	if surface then -- on_surface_deleted surface is already deleted
		local radars = surface.find_entities_filtered{ type="radar", name="radar" }
		for _, radar in ipairs(radars) do
			update_radar_channel(radar)
		end
	end
end
for _, event in ipairs({
	defines.events.on_surface_cleared,
	defines.events.on_surface_created,
	defines.events.on_surface_deleted,
	defines.events.on_surface_imported,
}) do script.on_event(event, function(event)
	--game.print(">> on_surface_event: ".. serpent.block(event))
	_surface_event(event.surface_index, game.surfaces[event.surface_index])
end) end

local function debug_vis_wires(surface, time_to_live, origin)
	local function _vis(entities)
		for _, w in ipairs({
			{t=W.circuit_red  , col = { 1, .2, .2 }, offset={x=0, y=0}},
			{t=W.circuit_green, col = { .2, 1, .2 }, offset={x=-.1, y=-.1}},
		}) do
			for _, e in ipairs(entities) do
				local con = e.get_wire_connectors()
				con = con[w.t] and con[w.t].connections or {}
				--game.print(">> con: ".. serpent.block(con))
				for _, c in ipairs(con) do
					if c.origin == origin then
						local from = { entity=e, offset=w.offset }
						local to = { entity=c.target.owner, offset=w.offset }
						if from.entity.surface ~= surface then from = { position=from.entity.position, offset=w.offset } end
						if   to.entity.surface ~= surface then   to = { position=  to.entity.position, offset=w.offset } end
						
						rendering.draw_line{ from = from, to = to, color = w.col, width = 2, surface = surface, time_to_live = time_to_live }
						rendering.draw_line{ from = from, to = to, color = w.col, width = 8, surface = surface, time_to_live = time_to_live, render_mode="chart" }
					end
				end
			end
		end
	end
	
	_vis(surface.find_entities_filtered{ name="radar" })
	_vis(surface.find_entities_filtered{ name="hexcoder_radar_uplink-cc" })
	_vis(surface.find_entities_filtered{ name="hexcoder_radar_uplink-dc" })
end

----
local function init(event)
	storage.open_guis = {}
	storage.radars = {}
	storage.platforms = {} 
	storage.polling_radars = {}
	storage.polling_platforms = {}
	storage.chsurfaces = {}
	
	for id, surface in pairs(game.surfaces) do
		_surface_event(id, surface)
	end
end
local function _reset(event) -- allow me to fix outdated state during dev
	for _, player in pairs(game.players) do player.opened = nil end
	storage.open_guis = nil
	storage.radars = nil
	storage.platforms = nil
	storage.polling_radars = nil
	storage.polling_platforms = nil
	storage.chsurfaces = nil
	
	for _, s in pairs(game.surfaces) do
		for _, e in pairs(s.find_entities_filtered{ name="hexcoder_radar_uplink-cc" }) do
			e.destroy()
		end
		for _, e in pairs(s.find_entities_filtered{ name="hexcoder_radar_uplink-dc" }) do
			e.destroy()
		end
		for _, e in pairs(s.find_entities_filtered{ name="hexcoder_radar_uplink-ac" }) do
			e.destroy()
		end
		for _, e in pairs(s.find_entities_filtered{ name="hexcoder_radar_uplink-pc" }) do
			e.destroy()
		end
	end
	
	init()
end
script.on_init(function(event)
	init()
end)

---@param ghost LuaEntity|BlueprintEntity
---@param settings RadarSettings
local function set_tags(ghost, settings)
	local tags = ghost.tags or {}
	tags["hexcoder_radar_uplink"] = settings
	ghost.tags = tags
end
---@param ghost LuaEntity|BlueprintEntity
---@param entity_id unit_number
---@return boolean
local function settings_to_tags(ghost, entity_id)
	local data = storage.radars[entity_id]
	if data then
		set_tags(ghost, data.S)
		return true
	end
	return false
end

---@param data PlatformData
local function update_platform_status(data)
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
local function update_platform_requests_at_planet(data)
	local plat = data.platform
	
	local signals = {} -- temporary table of signals, could avoid this via LuaLogisticSection.set_slot, but may be slower due to more api calls(?)
	table.insert(signals, { value={ type="virtual", name="signal-info", quality="normal" }, min=1 })
	
	-- Platform hub logistic points, for hubs we seem to always have 2: { requester, passive_provider }
	local logi = plat.hub.get_logistic_point()[1]
	if logi.filters then
		game.print(">> filters: ")
		-- filters are already compiled (all requests for one item summed) and filtered by import_from planet (unlike raw sections)
		for _, fil in ipairs(logi.filters) do
			game.print(" > ".. serpent.line(fil))
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
local function update_platform_pod_deliveries(plat)
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
local function platform_valid(p)
	-- platforms being built don't have a hub yet
	return (p and p.valid and p.hub and p.hub.valid) or false
end

---@param platform LuaSpacePlatform
---@return PlatformData
local function init_platform(platform)
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
local function reset_platform(id)
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
			 when vanilla mode selection: resets: despawns combinators, clears from custom tables
	reset: explicitly reset all custom data
	
	never keep entities with vanilla mode selection radar table nor have combinators for them spawned
	still allow gui to display and modify settings by letting it remeber return data table via init_radar, which it can pass into refresh
	keep ghost entities separate, do not insert into storage, keep and modify their data in entity.tags, but allow gui to edit it by testing for ghosts in init and refresh
]]

---@param id unit_number
local function reset_radar(id)
	local data = storage.radars[id]
	if data then
		if data.dcs then
			for _,v in ipairs(data.dcs) do
				v.destroy()
			end
			data.dcs = nil -- handle open in gui case
		end
		storage.radars[id] = nil
		storage.polling_radars[id] = nil
	end
end
---@param data RadarData
local function refresh_radar(data)
	local entity = data.entity
	local id = data.id
	--game.print("refresh_radar: ".. serpent.block(data))
	
	-- write tags to ghosts on change (ui seems to get a copy, possibly because entity.tags is behind API which copies)
	if entity.type == "entity-ghost" then
		set_tags(entity, data.S)
		return
	end
	-- delete data and spawned entities if vanilla mode
	if data.S.mode == nil then
		reset_radar(id)
		return
	end
	
	local platform = entity.force.platforms[data.S.selected_platform]
	local plat_data = platform_valid(platform) and init_platform(platform) or nil
	
	-- TODO: Make combinators 3x3 and place exactly on radar to automatically handle signals stopping if no power
	-- TODO: hdie power icons and power draw from power stats, and hide in everywhere in general?
	if not data.dcs then
		data.dcs = {}
		for i=1,2 do
			data.dcs[i] = entity.surface.create_entity{
				name="hexcoder_radar_uplink-dc", force=entity.force,
				position={entity.position.x+i-2, entity.position.y+0.5}, snap_to_grid=false,
				direction=defines.direction.south
			}
			data.dcs[i].destructible = false
		end
	end
	
	local planet_sig = {type="space-location", name=entity.surface.planet.prototype.name}
	---@type DeciderCombinatorParameters[]
	local params = {
		{conditions={
			{first_signal={type="virtual", name="signal-each"}, constant=0, comparator="!=", first_signal_networks=netR}
		},outputs={
			{signal={type="virtual", name="signal-each"}, copy_count_from_input=true, networks=netR}
		}},
		
		{conditions={
			{first_signal={type="virtual", name="signal-each"}, constant=0, comparator=">", first_signal_networks=netR},
			{first_signal=planet_sig, constant=0, comparator=">", compare_type="and", first_signal_networks=netG},
		},outputs={
			{signal={type="virtual", name="signal-each"}, copy_count_from_input=true, networks=netR}
		}},
	}
	local R = entity.get_wire_connectors(true)
	local dcStat = data.dcs[1].get_wire_connectors(true)
	local dcReq = data.dcs[2].get_wire_connectors(true)
	
	local RG = { data.S.read_plat_status and data.S.read_plat_statusRG or 0,
	             data.S.read_plat_requests and data.S.read_plat_requestsRG or 0 }
	for i=1,2 do
		local combinator = data.dcs[i]
		local ctrl = combinator.get_control_behavior() --[[@as LuaDeciderCombinatorControlBehavior]]
		ctrl.parameters = params[i]
		local con = combinator.get_wire_connectors(true)
		
		con[W.combinator_output_red  ].disconnect_all(HIDDEN)
		con[W.combinator_output_green].disconnect_all(HIDDEN)
		if RG[i] % 2 > 0 then con[W.combinator_output_red  ].connect_to(R[W.circuit_red  ], false, HIDDEN)  end
		if RG[i] >= 2    then con[W.combinator_output_green].connect_to(R[W.circuit_green], false, HIDDEN)  end
	end
	
	local dcStatR = dcStat[W.combinator_input_red]
	local connected = plat_data and dcStatR.connection_count == 1
		and dcStatR.connections[1].target.owner.surface == platform.surface
	if not connected then 
		dcStat[W.combinator_input_red  ].disconnect_all(HIDDEN)
		dcStat[W.combinator_input_green].disconnect_all(HIDDEN)
		dcReq[W.combinator_input_red  ].disconnect_all(HIDDEN)
		dcReq[W.combinator_input_green].disconnect_all(HIDDEN)
		
		if plat_data then
			--game.print("reconnect!")
			
			local rStat = plat_data.readers.stat.get_wire_connectors(true)
			local rReq = plat_data.readers.req.get_wire_connectors(true)
			local rOtw = plat_data.readers.otw_neg.get_wire_connectors(true)
			local rInv = plat_data.readers.inv_neg.get_wire_connectors(true)
			
			-- platform status to platform status on red wire
			dcStatR.connect_to(rStat[W.combinator_output_red], false, HIDDEN)
			
			-- platform raw requests to request on red wire
			-- platform status to requests on green wire for planet check
			dcReq[W.combinator_input_red].connect_to(rReq[W.combinator_output_red], false, HIDDEN)
			dcReq[W.combinator_input_red].connect_to(rOtw[W.combinator_output_red], false, HIDDEN)
			dcReq[W.combinator_input_red].connect_to(rInv[W.combinator_output_red], false, HIDDEN)
			dcReq[W.combinator_input_green].connect_to(rStat[W.combinator_output_green], false, HIDDEN)
			
			connected = true
		end
	end
	
	storage.radars[id] = data
	storage.polling_radars[id] = (not connected) and data or nil -- poll if not connected yet due to to platform build pending
end
---@param entity LuaEntity
---@param copy_settings RadarSettings?
---@return RadarData
local function init_radar(entity, copy_settings)
	local S
	if copy_settings then
		S = util.table.deepcopy(copy_settings)
	elseif entity.tags then -- handle allowing gui from ghost entities
		S = entity.tags["hexcoder_radar_uplink"]
	else S = { -- settings
			mode = nil, -- nil: default circuit sharing mode, "platforms": circuits read platforms
			read_plat_status = true,
			read_plat_statusRG = 3,
			read_plat_requests = true,
			read_plat_requestsRG = 3,
			selected_platform = nil, -- LuaSpacePlatform.index
		}
	end ---@cast S RadarSettings
	
	local id = entity.unit_number
	local data = storage.radars[id]
	if not data then
		script.register_on_object_destroyed(entity)
		
		data = { id = id, entity = entity, S = S }
	end
	
	refresh_radar(data)
	return data
end

-- Only update platform list any time radar gui is opened, as updating it in tick seems to mess with drop down (having to spam click for it to close)
-- I think setting drop_down.items while it is open breaks it (?)
-- Keep track of platform by LuaPlatform not name, not sure if this is ideal or if by name would be better
---@param gui OpenGui
---@param data RadarData
local function radar_gui_update_platforms(gui, data)
	-- In theory this only needs to be updated once per tick, but each player can only have one gui open anyway
	-- duplicates work in multiplayer, but in theory players could each have different forces!
	local drop_down_strings = {"[None]"}
	local drop_down_platforms = {nil}
	local counter = 2 -- next platform in list
	local sel_idx = nil
	
	local force = data.entity and data.entity.valid and data.entity.force
	if force then
		for i, platf in pairs(force.platforms) do
			--game.print(" > ".. i .."platform ".. platf.name)
			
			local name = platf.name
			if not platform_valid(platf) then name = name.." (Not fully built)"
			elseif platf.scheduled_for_deletion ~= 0 then name =
				name.." [color=#f00000][virtual-signal=signal-trash-bin] (Scheduled for deletion)[/color]" end
			
			drop_down_strings[counter] = name
			drop_down_platforms[counter] = platf.index
			
			-- if platform still found in list (by identity, not name), keep it selected, if not select [None]
			if data.S.selected_platform == platf.index then
				sel_idx = counter
			end
			counter = counter+1
		end
	end
	
	if not sel_idx then -- selected_platform not found, it could have been deleted
		data.S.selected_platform = nil
		sel_idx = 1 -- [None]
	end
	
	gui.drop_down_platforms = drop_down_platforms
	gui.refs.platform_drop_down.items = drop_down_strings
	gui.refs.platform_drop_down.selected_index = sel_idx
end

-- update ui from data
---@param gui OpenGui
---@param data RadarData
local function radar_update_gui(gui, data)
	radar_gui_update_platforms(gui, data)
	
	gui.refs.mode1.state = data.S.mode == nil
	gui.refs.mode2.state = data.S.mode == "platforms"
	
	gui.refs.option1.state = data.S.read_plat_status
	gui.refs.option2.state = data.S.read_plat_requests
	
	gui.refs.option1R.state = data.S.read_plat_statusRG % 2 > 0
	gui.refs.option1G.state = data.S.read_plat_statusRG >= 2
	gui.refs.option2R.state = data.S.read_plat_requestsRG % 2 > 0
	gui.refs.option2G.state = data.S.read_plat_requestsRG >= 2
	
	gui.refs.vanilla_pane.visible = gui.refs.mode1.state
	gui.refs.platforms_pane.visible = gui.refs.mode2.state
	
	-- radar_gui_update_platforms can reset selected_platform
	-- this causes a radar refresh every time the gui is opened, which is probably a good idea anywy
	refresh_radar(data)
end

-- update data from ui
---@param event EventData.on_gui_checked_state_changed
function handlers.radar_checkbox(event)
	local gui = storage.open_guis[event.player_index]
	local data = gui.data
	
	if     event.element.name == "mode1" then data.S.mode = nil
	elseif event.element.name == "mode2" then data.S.mode = "platforms"
	elseif event.element.name == "option1" then data.S.read_plat_status = event.element.state
	elseif event.element.name == "option2" then data.S.read_plat_requests = event.element.state end
	
	data.S.read_plat_statusRG   = (gui.refs.option1R.state and 1 or 0) + (gui.refs.option1G.state and 2 or 0)
	data.S.read_plat_requestsRG = (gui.refs.option2R.state and 1 or 0) + (gui.refs.option2G.state and 2 or 0)
	
	gui.refs.mode1.state = data.S.mode == nil
	gui.refs.mode2.state = data.S.mode == "platforms"
	
	gui.refs.vanilla_pane.visible = gui.refs.mode1.state
	gui.refs.platforms_pane.visible = gui.refs.mode2.state
	
	refresh_radar(data)
	
	if event.element.name == "mode1" or event.element.name == "mode2" then
		update_radar_channel(data.entity)
	end
end
---@param event EventData.on_gui_selection_state_changed
function handlers.radar_drop_down(event)
	local gui = storage.open_guis[event.player_index]
	local data = gui.data
	
	if event.element.name == "platform_drop_down" then
		data.S.selected_platform = gui.drop_down_platforms[event.element.selected_index]
	end
	
	radar_gui_update_platforms(gui, data)
	refresh_radar(data)
end
---@param event EventData.on_gui_click
function handlers.entity_window_close_button(event)
	-- actually trigger entity close on close button click (calls on_gui_closed)
	game.get_player(event.player_index).opened = nil
end

---@param player LuaPlayer
---@param entity LuaEntity
---@return LuaGuiElement
local function create_radar_gui(player, entity)
	local data = init_radar(entity)
	
	-- TODO: cursor is not finger pointer on draggable titlebar like with built in guis?
	local window, refs = glib.add(player.gui.screen,
		default_frame("hexcoder_radar_uplink", "Radar circuit connection", { button=handlers.entity_window_close_button }))
	window.force_auto_center()
	
	local status_descr = [[Read space platform status with unlimited range.
	[virtual-signal=signal-P]: Platform ID
	[space-location=nauvis]=1  Currently orbited planet - Check using [space-location=nauvis]>0
	[space-location=nauvis]=-1 [space-location=gleba]=2  Travelling on space connection [space-location=nauvis]->[space-location=gleba] - Platform travel direction is respected
	[space-location=aquilo]=-10  Actually targetted planet in next schedule stop
	[virtual-signal=signal-T]  Space connection progress in % and [virtual-signal=signal-D] in km]]
	
	local request_descr = [[Read unfulfilled space platform requests.
	Limited to platforms in orbit - signal indicated by [virtual-signal=signal-info]]
	
	-- Convert from glib to manual 
	
	-- TODO: tooltips with explanations
	local frame, refs = glib.add(window, {
		args={type = "flow", direction = "horizontal"},
		style_mods = { natural_width=420 },
		children = {
			{args={type = "frame", direction = "vertical", style = "inside_shallow_frame_with_padding"}, style_mods={right_margin=8}, children={
				{args={type = "label", caption = "Operation mode", style="caption_label"}},
				{args={type = "radiobutton", name = "mode1", caption = "Global", state=true}, _checked_state_changed = handlers.radar_checkbox },
				{args={type = "radiobutton", name = "mode2", caption = "Platforms", state=false}, _checked_state_changed = handlers.radar_checkbox },
			}},
			{args={type = "frame", direction = "vertical", name="vanilla_pane", style = "inside_shallow_frame_with_padding"}, children={
				{args={type = "label", caption = "Vanilla behavior\nShare signals with other radars on this surface"}, style_mods={single_line=false}},
			}},
			{args={type = "frame", direction = "vertical", name="platforms_pane", style = "inside_shallow_frame_with_padding", visible=false}, children={
				{args={type = "flow", direction = "horizontal"}, children={
					{args={type = "label", caption = "Platform", style="caption_label"}, style_mods={margin={4, 5, 0, 0}} },
					{args={type = "drop-down", name = "platform_drop_down", caption = "Mode", items = {""}, selected_index = 1 },
					  style_mods={bottom_margin=5},
					  _selection_state_changed = handlers.radar_drop_down }
				}},
				{args={type = "flow", direction = "vertical"}, children={
					{args={type = "line"}},
					{args={type = "flow", direction = "horizontal"}, style_mods={top_margin=5}, children={
						{args={type = "checkbox", name = "option1", caption = "Read platform status", state=false, tooltip=status_descr},
						  style_mods={horizontally_stretchable=true}, _checked_state_changed = handlers.radar_checkbox },
						{args={type = "checkbox", name = "option1R", caption = "R", state=false}, _checked_state_changed = handlers.radar_checkbox },
						{args={type = "checkbox", name = "option1G", caption = "G", state=false}, _checked_state_changed = handlers.radar_checkbox },
					}},
					{args={type = "flow", direction = "horizontal"}, children={
						{args={type = "checkbox", name = "option2", caption = "Read platform requests", state=false, tooltip=request_descr}, style_mods={horizontally_stretchable=true}, _checked_state_changed = handlers.radar_checkbox },
						{args={type = "checkbox", name = "option2R", caption = "R", state=false}, _checked_state_changed = handlers.radar_checkbox },
						{args={type = "checkbox", name = "option2G", caption = "G", state=false}, _checked_state_changed = handlers.radar_checkbox },
					}},
				}}
			}},
		}
	}, refs)
	
	local gui = { refs=refs, data=data }
	storage.open_guis[player.index] = gui
	
	radar_update_gui(gui, data)
	
	return window
end

---- custom entity gui and handle blueprinting etc.
local _skip_closing_sound = nil
local function can_open_entity_gui(player, entity)
	return entity.valid and player.force == entity.force and player.can_reach_entity(entity)
end
-- TODO: enable configuring ghosts? If that is done, can I keep settings on building correctly? via tags? will gui stay open during build process?
script.on_event("hexcoder_radar_uplink-open-gui", function(event) ---@cast event EventData.CustomInputEvent
	--game.print("open-gui: ".. serpent.block(event))
	if not event.selected_prototype or not
	      (event.selected_prototype.name == "radar" or event.selected_prototype.name == "entity-ghost") then
		return
	end
	
	local player = game.get_player(event.player_index) ---@cast player -nil
	local entity = player.selected -- hovered entity or ghost
	
	local free_cursor = not (player.cursor_stack.valid_for_read or player.cursor_ghost or player.cursor_record)
	
	if free_cursor and entity and entity.valid and can_open_entity_gui(player, entity) then
		-- keep gui open if exact entity already open
		local gui = player.opened and storage.open_guis[player.index]
		if gui and entity.unit_number == gui.data.id then return end
		
		-- close regular or custom gui first
		_skip_closing_sound = true
		player.opened = nil
		_skip_closing_sound = nil
		
		-- guis in player.opened will close via E and Escape automatically
		player.opened = create_radar_gui(player, entity)
		
		player.play_sound{ path="hexcoder_radar_uplink-open-sound" }
	end
end)
-- called on player.opened=nil, on window close button, on E or Escape press
script.on_event(defines.events.on_gui_closed, function(event)
	if event.element and event.element.name == "hexcoder_radar_uplink" then
		storage.open_guis[event.player_index] = nil
		event.element.destroy()
		
		if not _skip_closing_sound then
			local player = game.get_player(event.player_index) ---@cast player -nil
			player.play_sound{ path="hexcoder_radar_uplink-close-sound" }
		end
	end
end)
---@param player LuaPlayer
---@param gui OpenGui
local function tick_gui(player, gui)
	-- close custom gui once out of reach
	if not can_open_entity_gui(player, gui.data.entity) then
		_skip_closing_sound = true
		player.opened = nil
		_skip_closing_sound = nil
	end
end

-- for custom entities with custom settings, close any gui and call reset_radar/reset_platform
script.on_event(defines.events.on_object_destroyed, function(event)
	game.print("on_object_destroyed: ".. serpent.line(event))
	for player_i, gui in pairs(storage.open_guis) do
		-- close open entity gui if entity destroyed
		if event.useful_id == gui.data.id then
			game.get_player(player_i).opened = nil
		end
	end
	
	if event.type == defines.target_type.entity then
		reset_radar(event.useful_id)
	else
		reset_platform(event.useful_id)
	end
end)

-- this allows blueprint to copy custom settings, and supports on_entity_cloned
-- TODO: blueprinting over does not trigger any events (could detect blueprint placed by player in other ways, but is complicated)
-- TODO: things being built due to undo redo don't work yet
local function on_created_entity(event)
	local entity = event.entity or event.destination
	--game.print("on_created_entity: ".. serpent.block({ event, entity }))
	
	local copy_settings = (event.tags and event.tags["hexcoder_radar_uplink"])
	                   or (event.source and storage.radars[event.source.unit_number].S)
	if copy_settings then
		init_radar(entity, copy_settings)
	end
	
	-- This needs to happen for all radars
	update_radar_channel(entity)
end
for _, event in ipairs({
	defines.events.on_built_entity,
	defines.events.on_robot_built_entity,
	defines.events.on_space_platform_built_entity,
	defines.events.script_raised_built,
	defines.events.script_raised_revive,
	defines.events.on_entity_cloned,
}) do
	script.on_event(event, on_created_entity, {{filter = "type", type = "radar"}, {filter = "name", name = "radar"}})
end
local function on_entity_removed(event)
	update_radar_channel(event.entity)
end
for _, event in ipairs({
	defines.events.on_entity_died,
	defines.events.on_player_mined_entity,
	defines.events.on_robot_pre_mined,
	defines.events.on_space_platform_pre_mined,
}) do
	script.on_event(event, on_entity_removed, {{filter = "type", type = "radar"}, {filter = "name", name = "radar"}})
end
-- for all radars: if dies apply tags to ghost to keep settings on revive
script.on_event(defines.events.on_post_entity_died, function(event)
	--game.print("on_post_radar_died: ".. serpent.block({event}))
	if event.ghost and event.unit_number then
		settings_to_tags(event.ghost, event.unit_number)
	end
end, {{filter = "type", type = "radar"}})

-- on_entity_settings_pasted doesn't get called for entities with no vanilla settings :(

script.on_event(defines.events.on_player_setup_blueprint, function(event)
	local player = game.get_player(event.player_index) ---@cast player -nil
	local blueprint = event.stack
	if not blueprint or not blueprint.valid_for_read then blueprint = player.blueprint_to_setup end
	if not blueprint or not blueprint.valid_for_read then blueprint = player.cursor_stack end
	if not blueprint or not blueprint.valid_for_read then return end
	
	local entities = blueprint.get_blueprint_entities()
	local mapping = nil
	if not entities then return end
	local changed = false
	
	for i, bp_entity in pairs(entities) do
		if bp_entity.name == "radar" then
			mapping = mapping or event.mapping.get()
			if settings_to_tags(bp_entity, mapping[i].unit_number) then
				-- need to modify name somehow if entity has custom name and and ghost version does not match somehow? (protocol_1903 [pY] on discord)
				changed = true
			end
		end
	end
	if changed then
		blueprint.set_blueprint_entities(entities)
	end
end)

-- tick certain things at 10x per second to conserve reduce load, is this a good idea or should we 'stagger' entity ticks?
script.on_nth_tick(6, function(event)
	for player_i, gui in pairs(storage.open_guis) do
		local player = game.get_player(player_i) ---@cast player -nil
		tick_gui(player, gui)
	end
	
	for _,data in ipairs(storage.polling_radars) do
		refresh_radar(data)
	end
	
	for _,data in ipairs(storage.polling_platforms) do
		update_platform_status(data)
	end
end)

---- Commands
commands.add_command("hexcoder_radar_uplink-vis", nil, function(command)
	-- debug: visualize connections
	for _, p in pairs(game.players) do
		debug_vis_wires(p.surface, 60*10, HIDDEN) --defines.wire_origin.radars)
	end
	
	--game.print("storage.open_guis:")
	--for k,v in pairs(storage.open_guis) do
	--	game.print(k ..": ".. serpent.line(v))
	--end
	--game.print("storage.platforms:")
	--for k,v in pairs(storage.platforms) do
	--	game.print(k ..": ".. serpent.line(v))
	--end
	--game.print("storage.radars:")
	--for k,v in pairs(storage.radars) do
	--	game.print(k ..": ".. serpent.line(v))
	--end
end)
commands.add_command("hexcoder_radar_uplink-reset", nil, function(command)
	_reset()
end)

glib.register_handlers(handlers)
