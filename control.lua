--[[
TODO: make sure open/close sounds actually count as gui sounds, so gui sound volume slider actually affects it
 -> probably should actually assign it as radar.open_sound in data-updates, even if still have to play it manually

TODO: rewrite gui to be less bad at next opportunity
TODO: switch channels over to being keyed on string again, this is safer to blueprint etc. (should switch platform as well!) (rename from gui should just update others or update on after asking)
 -> only show local channels and global ones exposed via interplanetary flag in gui
  -> make channels get lazily created by name per surface (from gui), -> set up hubs and already connect according to rules (which surfaces can connect to? search all of them for channels of same name)
  -> make gui figure out all "nearby channels", on_surface + planet<->platform + platform<->platform for direct space conn + any universal ones etc.
   -> on gui select switch to channel by rewiring
   -> update connections if rules change (like platform leaving orbit) -> cuts hubs connections but keeps channels selected
   -> only delete channels manually, but only create hubs on surface where radar has created or selected channel (channels won't pollute other surfaces unless connected to once?)
   -> sort drop down menu?

TODO: add enough features for platform read mode to support fully automated mixed rocket launches together with silo mod
 -> need to be able to read requests without hard-selecting platforms
 -> read total requests? Not sure if actually useful
 -> read number of orbiting platforms / read number of platforms with requests
 -> set selected platform to read by platform ID makes sense as it is already exposed in status
 -> set selected platform to read by index / by id (how to reliably pick platform to send mixed launches to?)
  -> radar tracks all orbiting platforms with non-zero requests sorted by id, circuit hard-selects number one of those via signal=1
 -> select_platform R/G  P=id selects by id, K=idx selects by idx of platforms with active request, L=idx by index of all orbiting or so
  -> want to avoid reading circuit every tick, but no event, so might have to poll at low rate
  -> confirm signal sounds sensible for switching read target, but user can just keep sending same platform (but confirm signal might avoid user having to memory cell)

TODO: make space age optional?
TODO: figure out correct dependency versions?

TODO: undo/redo? seems hard
TODO: blueprint over? hacky workaround but maybe not that hard?
TODO: copy paste? not really possible to to properly (with visual feedback?); but could fake using key events? not worth it if blueprint over works I think
--]]

---@type ModStorage
storage = storage

dbg = settings.startup["hexcoder_radar_uplink-debug"].value

function round(num)
	return num >= 0 and math.floor(num + 0.5) or math.ceil(num - 0.5)
end
netR = {red=true, green=false}
netG = {red=false, green=true}
W = defines.wire_connector_id
HIDDEN = dbg and defines.wire_origin.player or defines.wire_origin.script
--HIDDEN = defines.wire_origin.script

local radar_channels = require("script.radar_channels")
local radars = require("script.radars")
local radar_gui = require("script.radar_gui")
local myutil = require("script.myutil")
local util = require("util")

script.on_nth_tick(12, function(event)
	-- poll when gui is open to react to player walking out of reach of radar
	for player_id, gui in pairs(storage.open_guis) do
		local player = game.get_player(player_id)
		if player then
			radar_gui.tick_gui(player, gui)
		end
	end
	
	-- poll platforms that are currently moving to display real time status
	--for _,data in pairs(storage.polling_platforms) do
	-- Do this for all platform right now, to fix requests not reacting to user toggling sections
	for _,data in pairs(storage.platforms) do
		radars.poll_platform(data)
	end
end)

script.on_event(defines.events.on_tick, function(event)
	--if not storage.polling_radars_cur then return end
	
	-- update entire list and thus each entity exactly once every period
	local period = storage.settings.poll_period
	local list = storage.polling_radars
	local ratio = (event.tick % period) + 1 -- +1 only works with tick freq=1, period must be divisible by this, so 1 is good
	local last = math.ceil((ratio / period) * #list)
	
	for i=storage.polling_radars_cur,last do
		radars.poll_radar(list[i])
	end
	
	if ratio == period then -- end of list reached
		storage.polling_radars_cur = 1
	else
		storage.polling_radars_cur = last+1
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
	radars.init_radar(entity, copy_settings)
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

-- TODO: handle script_raised_teleported ? Liekly super rare but easy to handle (tempS=data.S, delete_radar + init_radar(, tempS))

-- for all radars: if dies apply tags to ghost to keep settings on revive
script.on_event(defines.events.on_post_entity_died, function(event)
	--game.print("on_post_radar_died: ".. serpent.block({event}))
	if event.ghost and event.unit_number then
		radars.settings_to_tags(event.ghost, event.unit_number)
	end
end, {{filter = "type", type = "radar"}})

-- for custom entities with custom settings, close any gui and call delete_radar/delete_platform
script.on_event(defines.events.on_object_destroyed, function(event)
	--game.print("on_object_destroyed: ".. serpent.line(event))
	if storage.open_guis then
		for player_i, gui in pairs(storage.open_guis) do
			-- close open entity gui if entity destroyed
			if event.useful_id == (gui and gui.data and gui.data.id) then
				game.get_player(player_i).opened = nil
			end
		end
	end
	
	if event.type == defines.target_type.entity then
		radars.delete_radar(event.useful_id)
	else
		radars.delete_platform(event.useful_id)
	end
end)

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
			mapping = mapping or event.mapping.get() --[[@as LuaEntity]]
			if radars.settings_to_tags(bp_entity, mapping[i].unit_number) then
				-- need to modify name somehow if entity has custom name and and ghost version does not match somehow? (protocol_1903 [pY] on discord)
				changed = true
			end
		end
	end
	if changed then
		blueprint.set_blueprint_entities(entities)
	end
end)

for _, event in ipairs({
	defines.events.on_surface_cleared,
	defines.events.on_surface_created,
	defines.events.on_surface_deleted,
	defines.events.on_surface_imported,
}) do script.on_event(event, function(event)
	--game.print(">> on_surface_event: ".. serpent.block(event))
	radar_channels.on_surface_event(event.surface_index)
end) end

---- init

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
	if event.setting == "hexcoder_radar_uplink-allow_interplanetary_comms" then
		storage.settings.allow_interpl = settings.global["hexcoder_radar_uplink-allow_interplanetary_comms"].value
		
		radars.refresh_all_custom_radars()
		radar_channels.update_all_channels_is_interplanetary()
	end
	
	storage.settings.poll_period = settings.global["hexcoder_radar_uplink-radar_poll_period"].value
end)

---@class player_index : integer
---@class unit_number : integer
---@class platform_index : integer
---@class surface_index : integer
---@class channel_id : number

---@class ModStorage
---@field settings ModSettings
---@field open_guis table<player_index, OpenGui>
---@field radars table<unit_number, RadarData>
---@field platforms table<platform_index, PlatformData>
-- ---@field polling_platforms table<platform_index, PlatformData>
---@field channels Channels
---@field polling_radars RadarData[]
---@field polling_radars_cur integer

---@class ModSettings
---@field allow_interpl boolean
---@field poll_period integer

local function init()
	storage = {}
	storage.settings = {
		allow_interpl = settings.global["hexcoder_radar_uplink-allow_interplanetary_comms"].value --[[@as boolean]],
		poll_period = settings.global["hexcoder_radar_uplink-radar_poll_period"].value --[[@as integer]],
	}
	storage.open_guis = {}
	storage.radars = {}
	storage.platforms = {} 
	--storage.polling_platforms = {}
	storage.channels = { next_id=1, map={}, surfaces={} }
	storage.polling_radars = {}
	storage.polling_radars_cur = 1
	
	local ch = radar_channels.create_new_channel()
	ch.name = "[Global]"
	ch.is_interplanetary = false
	
	for _, surface in pairs(game.surfaces) do
		for _, r in ipairs(surface.find_entities_filtered{ type="radar", name="radar" }) do
			radars.init_radar(r)
		end
	end
end
local function _reset() -- allow me to fix outdated state during dev
	for _, player in pairs(game.players) do player.opened = nil end
	
	for _, s in pairs(game.surfaces) do
		for _, name in pairs({"cc","dc","ac","pc"}) do
			for _, e in pairs(s.find_entities_filtered{ name="hexcoder_radar_uplink-"..name }) do
				e.destroy()
			end
		end
	end
	
	init()
end
script.on_init(function(event)
	init()
end)

-- First attempt at adding migrations
script.on_configuration_changed(function(data)
	local changes = data.mod_changes["hexcoder-radar-uplink"]
	if not changes then return end
	local old = changes.old_version
	if not old then return end -- on_init already handles existing save
	
	if myutil.version_less(old, "1.3.0") then
		local channels = util.table.deepcopy(storage.channels or {}) -- deepcopy just to be safe
		local old_radars = util.table.deepcopy(storage.radars or {})
		
		_reset()
		
		local new_platforms = {}
		for _,force in pairs(game.forces) do
			new_platforms[force.index] = {}
			for id,plat in pairs(force.platforms) do
				new_platforms[force.index][id] = plat
			end
		end
		
		storage.channels.next_id = channels.next_id or 1
		for id,ch in pairs(channels.map) do
			if type(id) == "number" and id > 1 and ch and ch.name and id < storage.channels.next_id then
				storage.channels.map[id] = { id=id, name=ch.name, is_interplanetary=ch.is_interplanetary or false }
			end
		end
		for id,data in pairs(storage.radars) do
			local old_data = old_radars[id]
			if old_data and old_data.entity and old_data.entity.valid and old_data.entity.unit_number and old_data.S then
				data.S.mode = old_data.S.mode == "platforms" and "platforms" or "comms"
				if old_data.S.mode == "platforms" then
					data.S.read_mode = old_data.S.read_mode == "raw" and "raw" or "std"
					data.S.read = data.S.read or {}
					for k,def in pairs(radars.radar_defaults["pl_"..data.S.read_mode]) do
						data.S.read[k] = old_data.S.read and old_data.S.read[k] or def
					end
					data.S.selected_platform = nil
					if new_platforms[data.entity.force.index][old_data.S.selected_platform] then
						data.S.selected_platform = old_data.S.selected_platform
					end
				else
					data.S.selected_channel = 0
					if storage.channels.map[old_data.S.selected_channel] then
						data.S.selected_channel = old_data.S.selected_channel
					end
				end
				
				radars.refresh_radar(data)
			end
		end
	end
end)

---- debugging
--[[
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
	
	_vis(surface.find_entities_filtered{ type="radar", name="radar" })
	_vis(surface.find_entities_filtered{ name="hexcoder_radar_uplink-cc" })
	_vis(surface.find_entities_filtered{ name="hexcoder_radar_uplink-dc" })
end

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
]]
commands.add_command("hexcoder_radar_uplink-reset", nil, function(command)
	_reset()
end)
