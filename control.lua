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
	storage.open_guis = nil
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
	return entity.valid and entity.type == "radar" and entity.name == "radar"
end
local function get_radar_data_or_init(entity)
	local data = get_entity_data(entity)
	if (not data) then
		local reg_id, unit_num = script.register_on_object_destroyed(entity)
		data = {
			read_plat_requests = false,
			read_plat_location = false,
			selected_platform = nil
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
	if (force) then
		for i, platf in pairs(force.platforms) do
			--game.print(" > ".. i .."platform ".. platf.name)
			
			drop_down_strings[counter] = platf.name
			drop_down_platforms[counter] = platf
			
			-- if platform still found in list (by identity, not name), keep it selected, if not select [None]
			if (data.selected_platform == platf) then
				sel_idx = counter
			end
			counter = counter+1
		end
	end
	
	if (not sel_idx) then -- selected_platform not found, it could have been deleted
		data.selected_platform = nil
		sel_idx = 1 -- [None]
	end
	
	gui.drop_down_platforms = drop_down_platforms
	gui.refs.platform_drop_down.items = drop_down_strings
	gui.refs.platform_drop_down.selected_index = sel_idx
end

function handlers.radar_checkbox(event)
	local data = get_entity_data(storage.open_guis[event.player_index].entity)
	
	if     (event.element.name == "mode1") then data.read_plat_requests = event.element.state
	elseif (event.element.name == "mode2") then data.read_plat_location = event.element.state end
	
	--game.print("radar_checkbox ".. serpent.block(data))
end
function handlers.radar_drop_down(event)
	local gui = storage.open_guis[event.player_index]
	local data = get_entity_data(gui.entity)
	
	if (event.element.name == "platform_drop_down") then
		data.selected_platform = gui.drop_down_platforms[event.element.selected_index]
	end
	
	game.print("radar_drop_down ".. serpent.block(data))
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
					--	{
					--		args = {type = "radiobutton", name = "radio1", caption = "Radio 1",
					--				state = data.mode == "vanilla" }
					--	},
					--	{
					--		args = {type = "radiobutton", name = "radio2", caption = "Radio 2",
					--				state = data.mode == "read_platform"}
					--	},
						{args = {type = "checkbox", name = "mode1", caption = "Read Platform Requests", state=false }, _checked_state_changed = handlers.radar_checkbox },
						{args = {type = "checkbox", name = "mode2", caption = "Read Platform Status", state=false }, _checked_state_changed = handlers.radar_checkbox },
					}
				}
			}
		--}
	}, refs)
	
	local gui = { refs=refs, entity=entity }
	storage.open_guis[player.index] = gui
	
	local data = get_radar_data_or_init(gui.entity)
	radar_gui_update(gui, data)
	
	player.play_sound{ path="hexcoder-radar-open-sound" }
	
	return window
end

local function open_custom_entity_gui(player, entity)
	local open_gui = player.opened and storage.open_guis[player.index]
	if (open_gui and entity == open_gui.entity) then return end
	game.print(">>> open radar gui", prnt)
	
	-- regular entity gui is closed and makes our UI close via E and Escape automatically
	-- close possible custom gui first to prevent name collsion
	player.opened = nil
	player.opened = create_radar_gui(player, entity)
end
script.on_event(defines.events.on_gui_closed, function(event)
	game.print(">>> on_gui_closed", prnt)
	if (event.element and event.element.name == "hexcoder_radar_gui") then
		local player = game.get_player(event.player_index)
		
		-- Dont bother with this if I cant get close sound to trigger only when closing, not when switching guis
		--if (event.element.name == "hexcoder_radar_gui") then
		--	player.play_sound{ path="hexcoder-radar-close-sound" }
		--end
		
		storage.open_guis[event.player_index] = nil
		event.element.destroy()
	end
end)
script.on_event(defines.events.on_object_destroyed, function(event)
	for player_i, gui in pairs(storage.open_guis) do
		-- close open entity gui if entity destroyed
		if (event.useful_id == gui.entity.unit_number) then
			game.get_player(player_i).opened = nil
		end
	end
	
	storage.data[event.useful_id] = nil
end)

-- reacting to LMB requires custom input(?)
script.on_event("hexcoder_left_click", function(event)
	local player = game.get_player(event.player_index)
	local free_cursor = not (player.cursor_stack.valid_for_read or player.cursor_ghost or player.cursor_record)
	local entity = player.selected -- hovered entity
	local can_open_gui = free_cursor and entity and entity.valid and player.can_reach_entity(entity)
	
	if (can_open_gui) then
		game.print(">>> on_entity_click ".. entity.name, prnt)
		
		if (is_radar(entity)) then
			open_custom_entity_gui(player, entity)
		end
	end
end)

script.on_nth_tick(6, function(event)
	for player_i, gui in pairs(storage.open_guis) do
		local player = game.get_player(player_i)
		-- close custom gui once out of reach
		local valid = gui.entity.valid and player.can_reach_entity(gui.entity)
		if (not valid) then
			player.opened = nil
		end
	end
end)
--script.on_nth_tick(defines.events.on_player_changed_position, function(event) -- Doesn't work?
--	game.print(">>> on_player_changed_position ")
--	
--	local gui = storage.open_guis[event.player_index]
--	if (gui) then
--		-- close custom gui once out of reach
--		local player = game.get_player(event.player_index)
--		local valid = gui.entity.valid and player.can_reach_entity(gui.entity)
--		if (not valid) then
--			player.opened = nil
--		end
--	end
--end)

script.on_nth_tick(60, function(event)
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
end)

glib.register_handlers(handlers)

script.on_event(defines.events.on_entity_cloned, function(event)
	
end, {{filter = "type", type = "radar"}, {filter = "name", name = "radar"}})
script.on_event(defines.events.on_entity_settings_pasted, function(event)
	if (is_radar(source) and is_radar(destination)) then
		
		--local gui = { refs=refs, entity=entity, entity_id=script.register_on_object_destroyed(entity) }
		--local gui = { refs=refs, entity=entity, entity_id=script.register_on_object_destroyed(entity) }
	end
end) -- can't filter

-- script_raised_teleported (machines can be moved by scripts using this?)
-- on_entity_cloned (machines can be duplicated by scripts using this, ex. SE trains with space elevator and spaceships?)

-- on_entity_settings_pasted
-- keep settings on upgrade? (not relevant for me I suppose?)
-- on_player_setup_blueprint ?

-- on_player_flipped_entity
-- on_player_rotated_entity