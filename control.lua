--[[
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

TODO:
 -> cargo landing pad is exactly the same as platform hub in terms of requests/otw/inv/slots, except for status, which could have planet=4?
 -> with unlimited reads, could actually include them in list universally,
    otherwise radars in orbit could have the special entry of "<Current planet> landing pad"?

TODO:
- implement channel restrictions
 -universal (any surface to surface)
 -planet<->orbit, and any orbit<->orbit (orbital relay at src and dst planets)
 -planet<->orbit, orbit<->nearby orbit (relays in space along entire space connection path)
 -planet<->nearby planet (?)
 -> also on space_connection -> can connect to orbit at both ends, but power draw could change dynamically based on distance
 -> actually power draw could be the limiting factor for where we can connect to, which modpacks could use in interesting ways
 -> like a shattered planet-like trip where you lose connection due to lack of power at some point
 
TODO:
 -add big power draw when connecting to orbit, or even scale power draw with space connection distance? (customizable)
  -> would probably require compound entity, though assember can vary power draw with beacons, API might allow assembler entities to have flexible power draw even without actual beacons
 -allow disabling charting and maybe vision too (charting because of ups cost, and for OCD since we use the radar for other purposes)
  -> also probably via compound entity
   one entitiy is the visible one a reskinned assember might be able to correctly show variable power draw in gui and power chart and allow changing the anim speed
   another is dynamically spawned for charting and for vision
   if vision can't be disabled make this the normal radar (but modified), so deinstalling the mod keeps radars
   -> can we actually turn radar into assembler entity and still be type=radar name=radar?


TODO: make space age optional?
TODO: figure out correct dependency versions?

TODO: undo/redo? seems hard
TODO: blueprint over? hacky workaround but maybe not that hard? -> possible with lib, but from my understanding performance would be bad if every mod did it
TODO: copy paste? not really possible to do properly (with visual feedback?); but could fake using key events? not worth it if blueprint over works I think
--]]

---@type ModStorage
storage = storage

DEBUG = true

local radar_channels = require("script.radar_channels")
local radars = require("script.radars")
local Platforms = require("script.platforms")
local radar_gui = require("script.radar_gui")
local migrations = require("script.migrations")
local myutil = require("script.myutil")

local SEL_POLL_PERIOD = 15

-- Keep in nth tick or also stagger_tick? maybe infrequently updating distance readings are cleaner if synched?
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
	local platforms = storage.platforms
	for _,data in pairs(storage.platforms.all_sorted) do
		platforms:poll_platform(data)
	end
end)

script.on_event(defines.events.on_tick, function(event)
	if DEBUG then
		if not _did_reset then
			migrations.migrate_less0_1_4()
			_did_reset = true
		end
	end
	
	storage.poll_dyn_select:stagger_tick(event.tick, SEL_POLL_PERIOD, radars.poll_dyn_select)
	storage.poll_power_check:stagger_tick(event.tick, POLL_PERIOD, radars.poll_radar)
end)

-- this allows blueprint to copy custom settings, and supports on_entity_cloned
-- TODO: blueprinting over does not trigger any events (could detect blueprint placed by player in other ways, but is complicated)
-- TODO: things being built due to undo redo don't work yet
local function on_created_entity(event)
	local entity = event.entity or event.destination --[[@as LuaEntity]]
	--game.print("on_created_entity: ".. serpent.block({ event, entity }))
	
	local copy_settings = radars.tags_to_settings(event.tags, entity.force --[[@as LuaForce]])
	                   or (event.source and storage.radars[event.source.unit_number].S)
	radars.init_radar(entity, copy_settings)
end

for _, event in pairs({
	defines.events.on_built_entity,
	defines.events.on_robot_built_entity,
	defines.events.on_space_platform_built_entity,
	defines.events.script_raised_built,
	defines.events.script_raised_revive,
	defines.events.on_entity_cloned,
}) do
	script.on_event(event, on_created_entity, {{filter = "type", type = "radar"}, {filter = "name", name = "radar"}})
end
-- TODO: handle script_raised_teleported ? Likely super rare but easy to handle (tempS=data.S, delete_radar + init_radar(, tempS))

-- for all radars: if dies apply tags to ghost to keep settings on revive
script.on_event(defines.events.on_post_entity_died, function(event)
	--game.print("on_post_radar_died: ".. serpent.block({event}))
	if event.ghost and event.unit_number then
		radars.settings_to_tags(event.ghost, event.unit_number)
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

script.on_event({
	defines.events.on_surface_cleared,
	defines.events.on_surface_created,
	defines.events.on_surface_deleted,
	defines.events.on_surface_imported,
}, radar_channels.on_surface_event)

local deathrattles = {} ---@type function(EventData.on_object_destroyed)[]
deathrattles[defines.target_type.entity] = function(event)
	if storage.open_guis then
		for player_i, gui in pairs(storage.open_guis) do
			-- close open entity gui if entity destroyed
			if event.useful_id == (gui and gui.data and gui.data.id) then
				game.get_player(player_i).opened = nil
			end
		end
	end
	
	radars.delete_radar(event.useful_id)
end
deathrattles[defines.target_type.space_platform] = function(event)
	storage.platforms:delete_platform(event.useful_id)
end
deathrattles[defines.target_type.planet] = function(event)
	storage.platforms:update_all_platforms_list()
end
deathrattles[defines.target_type.surface] = function(event)
	radar_channels.on_surface_event(event.useful_id)
end
deathrattles[defines.target_type.player] = function(event)
	radar_gui.force_close_gui(event.useful_id)
end
script.on_event(defines.events.on_object_destroyed, function(event)
	--game.print("on_object_destroyed: ".. serpent.line(event))
	local handler = deathrattles[event.type]
	if handler then handler(event) end
end)

---- init

ALLOW_INTERPL = settings.global["hexcoder_radar_uplink-allow_interplanetary_comms"].value --[[@as boolean]]
POLL_PERIOD = settings.global["hexcoder_radar_uplink-radar_poll_period"].value --[[@as integer]]

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
	if event.setting == "hexcoder_radar_uplink-allow_interplanetary_comms" then
		ALLOW_INTERPL = settings.global["hexcoder_radar_uplink-allow_interplanetary_comms"].value
		
		radars.refresh_all_radars()
		radar_channels.update_all_channels_is_interplanetary()
	else
		POLL_PERIOD = settings.global["hexcoder_radar_uplink-radar_poll_period"].value
	end
end)

---@class player_index : integer
---@class unit_number : integer
---@class platform_index : integer
---@class surface_index : integer
---@class channel_id : number

---@class ModStorage
---@field radars table<unit_number, RadarData>
---@field platforms Platforms
---@field channels Channels
---@field open_guis table<player_index, OpenGui>
---@field open_guis2 table<RadarData, OpenGui>
---@field poll_power_check TickList
---@field poll_dyn_select TickList

script.register_metatable("ArrayList", myutil.ArrayList)
script.register_metatable("TickList", myutil.TickList)
script.register_metatable("Platforms", Platforms)

function migrations.init()
	storage.open_guis = {}
	storage.open_guis2 = {}
	storage.radars = {}
	storage.platforms = Platforms.new()
	storage.channels = { next_id=1, map={}, surfaces={} }
	storage.poll_power_check = myutil.TickList.new()
	storage.poll_dyn_select = myutil.TickList.new()
	
	local ch = radar_channels.create_new_channel()
	ch.name = "[Global]"
	ch.is_interplanetary = false
	
	storage.platforms:update_all_platforms_list()
	
	for _, surface in pairs(game.surfaces) do
		for _, r in ipairs(surface.find_entities_filtered{ type="radar", name="radar" }) do
			radars.init_radar(r)
		end
	end
end
function migrations.reset()
	for _, player in pairs(game.players) do player.opened = nil end
	
	for _, s in pairs(game.surfaces) do
		for _, name in pairs({"cc","pulsegen_cc","dc","ac","pc"}) do
			for _, e in pairs(s.find_entities_filtered{ name="hexcoder_radar_uplink-"..name }) do
				e.destroy()
			end
		end
	end
	
	storage = {}
	migrations.init()
end

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
