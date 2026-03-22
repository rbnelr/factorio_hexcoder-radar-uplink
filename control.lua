local util = require("util")
local glib = require("__glib__/glib")
local default_frame = require("__glib__/examples/default_frame")
local prnt = {sound=defines.print_sound.never}

function init(event)
	storage.data = {} -- per entity data
	storage.open_guis = {}
end

local handlers = {}

function _reset(event) -- allow me to fix outdates state during dev
	storage.silos = nil
	storage.data = nil
	--storage.open_guis = nil
	for _, player in pairs(game.players) do player.opened = nil end
	
	init()
end
script.on_init(function(event)
	init()
end)

local function get_entity_data(entity)
	return storage.data[entity.unit_number]
end

local function is_radar(entity)
	return entity and entity.valid and entity.type == "radar" and entity.name == "radar"
end
local function get_radar_data_or_init(entity)
	local data = get_entity_data(entity)
	if not data then
		local reg_id, unit_num = script.register_on_object_destroyed(entity)
		data = {
			read_plat_requests = false,
			read_plat_location = false,
			selected_platform = nil -- LuaSpacePlatform.index
		}
		storage.data[unit_num] = data
	end
	return data
end

--[[
Ideas:
  Radar Control
  [platform checkbox]  | Circuit connection
  *platform status     | connected mode + config
  
  default option in dropdown should be [Default] -> Status: Communicating with all radars on surface
  
  -> Limit so platform status is known, but no cross planet communicaion and only with orbiting platforms?
   -> though arguably why even limit it like this? only use might be less spoiling of gleba science if made intelligent.
    -> simply add a "universal platform comms" and "universal named comms" settings options
  Note that right now radars can read platforms, but platforms cannot read surface, is that wrong?
   -> either for radars in space read default surface radar circuit / named radars
   -> or instead avoid requiring radars on platform and make platform itself have these options
   -> or, if radars can read and write, simply select platform on surface radar with send option (arrives as circuit on hub)
  
more ideas:
  platform status: In Orbit: Planet siganl (1), In Transit Platet from/to as 1/2 like hub, but number conflict, or rather space route signal?
  text (regex?) based filtering of platforms (like printf or regex, or wildcard? "Platform No %%" and then reads are summed?)
  could add text field to name radar, then allow radar to read signals from named radars specifically?
  
--]]

-- iterate space platform hub logistic requests and compute remaining requests (items on the way are only counted once rocket is launched, i think)
-- returns as table["<quality>"]["<item_name>"] = request_count_excluding_on_the_way
local function compute_platform_requests(to_platform, from_planet)
	-- Platform hub inventory (excludes hub_trash)
	local inv = to_platform.hub.get_inventory(defines.inventory.hub_main)
	-- Platform hub logistic points
	-- for hubs we have 2: { requester, passive_provider }, iterate both to be safe
	local logi = to_platform.hub.get_logistic_point()
	local reqests = {}
	
	for _, lp in pairs(logi) do
		
		for _, sec in pairs(lp.sections) do
			--game.print(" > sec: ".. serpent.block(sec.active))
			if sec.active then
				for _, fil in pairs(sec.filters) do
					--game.print(" > fil: ".. serpent.block(fil))
					-- we can ignore comparator since only =quality setting can have min (others only apply max count which does not result in requests, but the platform dropping items) 
					if fil and fil.import_from == from_planet
						  and fil.min and fil.min > 0
						  and fil.value and fil.value.type == "item" then
						--game.print(" > ".. fil.value.name .." ".. fil.value.quality .." ".. fil.min)
						
						local q = reqests[fil.value.quality]
						if not q then q = {}
							reqests[fil.value.quality] = q
						end
						
						local count = q[fil.value.name] or -inv.get_item_count({name=fil.value.name, quality=fil.value.quality})
						q[fil.value.name] = count + fil.min
					end
				end
			end
		end
		
		-- items on the way
		--game.print(" > targeted_items_deliver: ".. serpent.block(on_the_way))
		for _, item in pairs(lp.targeted_items_deliver) do
			local q = reqests[item.quality]
			local i = q and q[item.name]
			if i then
				q[item.name] = i - item.count
			end
		end
	end
	return reqests
end

local function get_radar_output_signals(data, radar, platf)
	local radar_planet = radar.surface.planet.prototype
	local signals = {}
	
	if platf and platf.valid then
		--game.print(">> radar ".. platf.name)
		if data.read_plat_location then
			-- signal space location that platform is orbiting
			if platf.space_location then
				table.insert(signals, { value={ type="space-location", name=platf.space_location.name, quality="normal" }, min=1 })
			end
			-- signal space connection platform travelling
			-- since space connections are not supported as signals, output from/to space locations as signals with -1/-2 value
			-- dont do 1/2 like platform hub, due to conflict with space_location, avoid using 2/3 to allow nauvis>0 as condition (use nauvis<0 to check if platform is leaving or arriving)
			if platf.space_connection then
				local from = platf.space_connection.from
				local to = platf.space_connection.to
				table.insert(signals, { value={ type="space-location", name=from.name, quality="normal" }, min=-1 })
				table.insert(signals, { value={ type="space-location", name=to.name, quality="normal" }, min=-2 })
			end
		end
		
		-- output effective requests items
		-- plus "info" signal to know if requests are active without checking space location
		if data.read_plat_requests
			  and platf.space_location == radar_planet
			  and platf.hub and platf.hub.valid then
			table.insert(signals, { value={ type="virtual", name="signal-info", quality="normal" }, min=1 })
			
			local effective_requests = compute_platform_requests(platf, radar_planet)
			for quality, items in pairs(effective_requests) do
				for item, count in pairs(items) do
					if count > 0 then
						table.insert(signals, { value={ type="item", name=item, quality=quality }, min=count })
					end
				end
			end
		end
	end
	
	return signals
end
local function tick_radars()
	for id, data in pairs(storage.data) do
		local entity = game.get_entity_by_unit_number(id)
		if entity and entity.valid then
			--if data.circuit_cc then data.circuit_cc.destroy() end
			--data.circuit_cc = nil
			
			if not data.circuit_cc then
				data.circuit_cc = entity.surface.create_entity{
					name="constant-combinator", force=entity.force,
					position={entity.position.x - 2, entity.position.y},
					direction = defines.direction.east
				}
			end
			local platf = data.selected_platform and entity.force.platforms[data.selected_platform]
			
			local cc = data.circuit_cc.get_control_behavior()
			cc.enabled = platf and platf.valid and entity.active and entity.energy > 0
			if cc.enabled then
				cc.sections[1].filters = get_radar_output_signals(data, entity, platf)
			else
				cc.sections[1].filters = {}
			end
			
			--game.print(">> radar ".. id)
			--game.print(">> entity: ".. serpent.block(entity))
			--game.print(">> data: ".. serpent.block(data))
			
			--local circ1 = entity.get_circuit_network(defines.wire_type.red)
		end
	end
end


-- Only update platform list any time radar gui is opened, as updating it in tick seems to mess with drop down (having to spam click for it to close)
-- I think setting drop_down.items while it is open breaks it (?)
-- Keep track of platform by LuaPlatform not name, not sure if this is ideal or if by name would be better
local function radar_gui_update_platforms(gui, data)
	-- In theory this only needs to be updated once per tick, but each player can only have one gui open anyway
	-- duplicates work in multiplayer, but in theory players could each have different forces!
	local drop_down_strings = {"[None]"}
	local drop_down_platforms = {nil}
	local counter = 2 -- next platform in list
	local sel_idx = nil -- [None]
	
	local force = gui.entity and gui.entity.valid and gui.entity.force
	if force then
		for i, platf in pairs(force.platforms) do
			--game.print(" > ".. i .."platform ".. platf.name)
			
			drop_down_strings[counter] = platf.name
			drop_down_platforms[counter] = platf.index
			
			-- if platform still found in list (by identity, not name), keep it selected, if not select [None]
			if data.selected_platform == platf.index then
				sel_idx = counter
			end
			counter = counter+1
		end
	end
	
	if not sel_idx then -- selected_platform not found, it could have been deleted
		data.selected_platform = nil
		sel_idx = 1 -- [None]
	end
	
	gui.drop_down_platforms = drop_down_platforms
	gui.refs.platform_drop_down.items = drop_down_strings
	gui.refs.platform_drop_down.selected_index = sel_idx
end

function handlers.radar_checkbox(event)
	local data = get_entity_data(storage.open_guis[event.player_index].entity)
	
	if     event.element.name == "mode1" then data.read_plat_requests = event.element.state
	elseif event.element.name == "mode2" then data.read_plat_location = event.element.state end
	
	--game.print("radar_checkbox ".. serpent.block(data))
end
function handlers.radar_drop_down(event)
	local gui = storage.open_guis[event.player_index]
	local data = get_entity_data(gui.entity)
	
	if event.element.name == "platform_drop_down" then
		data.selected_platform = gui.drop_down_platforms[event.element.selected_index]
	end
	
	game.print("radar_drop_down ".. serpent.block(data))
	
	-- TODO: call radar_gui_update_platforms? 
	radar_gui_update_platforms()
end
function handlers.entity_window_close_button(event)
	-- need to call this on default_frame close button or else it will leave player.opened with invalid values
	game.get_player(event.player_index).opened = nil
end

function radar_gui_update(gui, data)
	radar_gui_update_platforms(gui, data)
	
	gui.refs.mode1.state = data.read_plat_requests
	gui.refs.mode2.state = data.read_plat_location
end

local function create_radar_gui(player, entity)
	local window, refs = glib.add(player.gui.screen,
		default_frame("hexcoder_radar_gui", "Radar Control", { button=handlers.entity_window_close_button }))
	window.force_auto_center()
	
	-- TODO: cursor is not finger pointer on draggable titlebar like with built in guis?
	glib.add(window, {
		--args = {type = "frame", direction = "vertical", style = "inside_shallow_frame_with_padding"},
		--style_mods = { size = {300, 100} }, children = {
			args = {type = "flow", direction = "vertical"},-- style = "inside_shallow_frame_with_padding"},
			--style_mods = { size = {200, 160} },
			children = {
				--{ args = {type = "label", caption = "Radar: ".. entity.backer_name or entity.name} },
				--{ args = {type = "line"} },
				{
					--args = {type = "flow", direction = "vertical"}, children = {
						args = {
							type = "drop-down", name = "platform_drop_down", caption = "Mode",
							items = {"[None]"}, selected_index = 1
						},
						_selection_state_changed = handlers.radar_drop_down
					--},
				},
				{
					args = {type = "flow", direction = "vertical"}, children = {
						{args = {type = "checkbox", name = "mode1", caption = "Read Platform Requests", state=false }, _checked_state_changed = handlers.radar_checkbox },
						{args = {type = "checkbox", name = "mode2", caption = "Read Platform Status", state=false }, _checked_state_changed = handlers.radar_checkbox },
					}
				}
			}
		--}
	}, refs)
	
	local gui = { refs=refs, entity=entity }
	storage.open_guis[player.index] = gui
	
	local data = get_radar_data_or_init(entity)
	radar_gui_update(gui, data)
	
	player.play_sound{ path="hexcoder-radar-open-sound" }
	
	return window
end

local function open_custom_entity_gui(player, entity)
	local open_gui = player.opened and storage.open_guis[player.index]
	if open_gui and entity == open_gui.entity then return end
	game.print("open radar gui", prnt)
	
	-- regular entity gui is closed and makes our UI close via E and Escape automatically
	-- close possible custom gui first to prevent name collsion
	player.opened = nil
	player.opened = create_radar_gui(player, entity)
end
script.on_event(defines.events.on_gui_closed, function(event)
	--game.print("on_gui_closed", prnt)
	if event.element and event.element.name == "hexcoder_radar_gui" then
		local player = game.get_player(event.player_index)
		
		-- Dont bother with this if I cant get close sound to trigger only when closing, not when switching guis
		--if event.element.name == "hexcoder_radar_gui" then
		--	player.play_sound{ path="hexcoder-radar-close-sound" }
		--end
		
		storage.open_guis[event.player_index] = nil
		event.element.destroy()
	end
end)
script.on_event(defines.events.on_object_destroyed, function(event)
	for player_i, gui in pairs(storage.open_guis) do
		-- close open entity gui if entity destroyed
		if gui.entity and gui.entity.valid and event.useful_id == gui.entity.unit_number then
			game.get_player(player_i).opened = nil
		end
	end
	
	storage.data[event.useful_id] = nil
end)

-- reacting to LMB requires custom input(?)
script.on_event("hexcoder_left_click", function(event)
	local player = game.get_player(event.player_index)
	local entity = player.selected -- hovered entity
	local free_cursor = not (player.cursor_stack.valid_for_read or player.cursor_ghost or player.cursor_record)
	
	if free_cursor then
		if is_radar(entity) and player.can_reach_entity(entity) then
			open_custom_entity_gui(player, entity)
		end
	end
end)

script.on_nth_tick(6, function(event)
	for player_i, gui in pairs(storage.open_guis) do
		local player = game.get_player(player_i)
		-- close custom gui once out of reach
		local valid = gui.entity.valid and player.can_reach_entity(gui.entity)
		if not valid then
			player.opened = nil
		end
	end
end)

-- this now allows blueprint to copy custom settings, supports on_entity_cloned
-- blueprinting over does not
-- entities dying due to damage don't keep settings yet
-- things being built due to undo redo don't work yet
local function on_created_entity(event)
	game.print("on_created_entity (".. serpent.block(event) ..")")
	game.print(serpent.block(event.tags))
	
	local entity = event.entity or event.destination
	
	--if event.source then
	--	storage.data[entity.unit_number] = util.table.deepcopy(storage.data[event.source.unit_number])
	--elseif event.tags then
	--	storage.data[entity.unit_number] = util.table.deepcopy(event.tags["hexcoder_radar_gui"])
	--end
	if event.source then
		storage.data[entity.unit_number] = storage.data[event.source.unit_number]
	elseif event.tags then
		storage.data[entity.unit_number] = event.tags["hexcoder_radar_gui"]
	end
end
for _, event in ipairs({
	defines.events.on_built_entity,
	defines.events.on_robot_built_entity,
	defines.events.on_space_platform_built_entity,
	defines.events.script_raised_built,
	defines.events.script_raised_revive,
	defines.events.on_entity_cloned,
}) do script.on_event(event, on_created_entity
--, {{filter = "type", type = "radar"}, {filter = "name", name = "radar"}}
) end

script.on_event(defines.events.on_player_setup_blueprint, function (event)
	local player = game.get_player(event.player_index)
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
			local entity = mapping[i]
			if is_radar(entity) then
				game.print("entity.storage: ".. serpent.block(storage.data[entity.unit_number]))
				
				local tags = bp_entity.tags or {}
				tags["hexcoder_radar_gui"] = storage.data[entity.unit_number]
				bp_entity.tags = tags
				-- need to modify name somehow if entity has custom name and and ghost version does not match somehow? (protocol_1903 [pY] on discord)
				
				--game.print("set tags to: ".. serpent.block(bp_entity.tags))
				--game.print("set tags to: ".. serpent.block(blueprint.get_blueprint_entity_tag(i, "hexcoder_radar_gui")))
				
				changed = true
			end
		end
	end
	if changed then
		blueprint.set_blueprint_entities(entities)
	end
end)

-- doesn't get called for entities with no vanilla settings :(
script.on_event(defines.events.on_pre_entity_settings_pasted, function(event)
	game.print("on_pre_entity_settings_pasted")
end)
script.on_event(defines.events.on_entity_settings_pasted, function(event)
	game.print("on_entity_settings_pasted")
end)

script.on_nth_tick(1, function(event)
	
	--for _, player in pairs(game.players) do
	--	game.print(">> cursor: ")
	--	game.print(">>  cursor_stack: ".. serpent.block(player.cursor_stack))
	--	game.print(">>  cursor_ghost: ".. serpent.block(player.cursor_ghost))
	--	game.print(">>  cursor_record: ".. serpent.block(player.cursor_record))
	--	game.print(">>  has_cursor: ".. (has_cursor and "true" or "false"))
	--end
	
	--for player_i, gui in pairs(storage.open_guis) do
	--	gui.entity.clone{position={x=gui.entity.position.x+5, y=gui.entity.position.y}}
	--end
	
	tick_radars()
end)

-- script_raised_teleported 
-- on_player_flipped_entity
-- on_player_rotated_entity

--[[
found this: might this make gui even simpler?

data:extend({
  {
    type = "custom-input", key_sequence = "",
    name = mod_prefix .. "open-gui",
    linked_game_control = "open-gui",
    include_selected_prototype = true,
  }
})


--]]

glib.register_handlers(handlers)
