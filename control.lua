--[[
TODO: make space age optional?
TODO: figure out correct dependency versions?

TODO: energy use: hide combinators in power graph, or make them not use power, accept that these signals work without power or add a (60 tick period) power check?

TODO: radars can currently send data to other radars without power, how to fix?
  Seems to be impossible without polling each radar, maybe just don't care?
  Or could alternate and update each rader every 60th tick, then dis or reconnect to hub, this might be acceptable

TODO: undo/redo? seems hard
TODO: blueprint over? hacky workaround but maybe not that hard?
TODO: copy paste? not really possible to to properly (with visual feedback?); but could fake using key events? not worth it if blueprint over works I think
--]]

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
---@field polling_radars table<unit_number, RadarData>
---@field polling_platforms table<platform_index, PlatformData>
---@field channels Channels

---@class ModSettings
---@field allow_interpl boolean

---@type ModStorage
storage = storage

dbg = settings.startup["hexcoder_radar_uplink-debug"].value

function round(num)
	return num >= 0 and math.floor(num + 0.5) or math.ceil(num - 0.5)
end
netR = {red=true, green=false}
netG = {red=false, green=true}
W = defines.wire_connector_id
--HIDDEN = dbg and defines.wire_origin.player or defines.wire_origin.script
HIDDEN = defines.wire_origin.script

local radar_channels = require("script.radar_channels")
local radars = require("script.radars")
local radar_gui = require("script.radar_gui")

-- this allows blueprint to copy custom settings, and supports on_entity_cloned
-- TODO: blueprinting over does not trigger any events (could detect blueprint placed by player in other ways, but is complicated)
-- TODO: things being built due to undo redo don't work yet
local function on_created_entity(event)
	local entity = event.entity or event.destination
	--game.print("on_created_entity: ".. serpent.block({ event, entity }))
	
	local copy_settings = (event.tags and event.tags["hexcoder_radar_uplink"])
	                   or (event.source and storage.radars[event.source.unit_number].S)
	if copy_settings then
		radars.init_radar(entity, copy_settings)
	end
	
	-- This needs to happen for all radars
	radar_channels.update_radar_channel(entity)
end
local function on_entity_removed(event)
	radar_channels.update_radar_channel(event.entity)
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
		radars.settings_to_tags(event.ghost, event.unit_number)
	end
end, {{filter = "type", type = "radar"}})

-- for custom entities with custom settings, close any gui and call reset_radar/reset_platform
script.on_event(defines.events.on_object_destroyed, function(event)
	--game.print("on_object_destroyed: ".. serpent.line(event))
	for player_i, gui in pairs(storage.open_guis) do
		-- close open entity gui if entity destroyed
		if event.useful_id == gui.data.id then
			game.get_player(player_i).opened = nil
		end
	end
	
	if event.type == defines.target_type.entity then
		radars.reset_radar(event.useful_id)
	else
		radars.reset_platform(event.useful_id)
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
			mapping = mapping or event.mapping.get()
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
	radar_channels.on_surface_event(event.surface_index, game.surfaces[event.surface_index])
end) end

-- tick certain things at 10x per second to reduce load, is this a good idea or should we 'stagger' entity ticks?
script.on_nth_tick(6, function(event)
	for player_i, gui in pairs(storage.open_guis) do
		local player = game.get_player(player_i) ---@cast player -nil
		radar_gui.tick_gui(player, gui)
	end
	
	for _,data in ipairs(storage.polling_radars) do
		radars.refresh_radar(data)
	end
	
	for _,data in ipairs(storage.polling_platforms) do
		radars.update_platform_status(data)
	end
end)

---- init

local function init(event)
	storage.settings = {
		allow_interpl = settings.global["hexcoder_radar_uplink-allow_interplanetary_comms"].value
	}
	storage.open_guis = {}
	storage.radars = {}
	storage.platforms = {} 
	storage.polling_radars = {}
	storage.polling_platforms = {}
	storage.channels = { next_id=1, map={}, surfaces={} }
	
	local ch = radar_channels.create_new_channel()
	ch.name = "[Global]"
	ch.is_interplanetary = false
	
	for _, surface in pairs(game.surfaces) do
		radar_channels.on_surface_event(surface.index, surface)
	end
end
local function _reset(event) -- allow me to fix outdated state during dev
	for _, player in pairs(game.players) do player.opened = nil end
	storage.settings = nil
	storage.open_guis = nil
	storage.radars = nil
	storage.platforms = nil
	storage.polling_radars = nil
	storage.polling_platforms = nil
	storage.channels = nil
	
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

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
	if event.setting == "hexcoder_radar_uplink-allow_interplanetary_comms" then
		storage.settings.allow_interpl = settings.global["hexcoder_radar_uplink-allow_interplanetary_comms"].value
		
		radars.refresh_all_custom_radars()
		radar_channels.update_all_channels_is_interplanetary()
	end
end)

---- debugging

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
