local glib = require("__glib__/glib")
local default_frame = require("__glib__/examples/default_frame")
local prnt = {sound=defines.print_sound.never}

function init(event)
	storage.open_guis = {}
end

local _do_reset = nil
function _reset(event)
	if (_do_reset) then _do_reset = false
		storage.silos = nil
		storage.data = nil
		storage.open_guis = nil
		
		init()
	end
end
script.on_init(function(event)
	init()
end)
script.on_load(function(event) -- during dev: reset storage fully to enable iterating without errors
	_do_reset = true
end)

--[[

script.on_event(defines.events.on_gui_opened, function(event)
	game.print(">>> on_gui_opened ".. event.player_index, prnt)
	if (event.gui_type == defines.gui_type.entity and event.entity and event.entity.valid) then
		local player = game.get_player(event.player_index)
		close_custom_window(player, true)
		if (event.entity.type == "rocket-silo") then
			on_gui_silo(player, event)
		end
	end
end)
script.on_event(defines.events.on_gui_closed, function(event)
	--game.print(">>> on_gui_closed")
	if (event.gui_type == defines.gui_type.entity and event.entity and event.entity.valid) then
		local player = game.get_player(event.player_index)
		
		local gui = player.gui.relative.hexcoder_silo_ctrl
		if (gui) then gui.destroy() end
	end
end)

function radar_gui_checked_changed(event)
	local gui = game.get_player(event.player_index).gui.screen.hexcoder_entity_gui
	local radar = get(gui.entity)
	
	if     (event.element.name == "radio1") then radar.read_plat_requests = event.element.state
	elseif (event.element.name == "radio2") then radar.read_plat_location = event.element.state end
end
function radar_gui_selection_changed(event)
	--if (event.element.name == "platform_drop_down") then
		--local gui = game.get_player(event.player_index).gui.screen.hexcoder_entity_gui
		--local radar = get(gui.entity)
		--if (radar and radar.entity and radar.entity.valid and radar.entity.force) then
		--	radar.selected_platform = gui.drop_down_platforms[event.element.selected_index]
		--end
	--end
end

local function radar_gui_update_platforms(gui, radar)
	-- In theory this only needs to be updates once per tick, but each player can only have one gui open anyway
	-- duplicates work in multiplayer, but in theory players could each have different forces!
	local drop_down_strings = {"[None]"}
	local drop_down_platforms = {nil}
	local counter = 2 -- next platform in list
	local sel_idx = nil -- [None]
	
	local force = radar.entity and radar.entity.valid and radar.entity.force
	if (force) then
		for i, platf in pairs(force.platforms) do
			--game.print(" > ".. i .."platform ".. platf.name)
			
			drop_down_strings[counter] = platf.name
			drop_down_platforms[counter] = platf
			
			-- if platform still found in list (by identity, not name), keep it selected, if not select [None]
			if (radar.selected_platform == platf) then
				sel_idx = counter
			end
			counter = counter+1
		end
	end
	
	if (not sel_idx) then -- selected_platform not found, it could have been deleted
		radar.selected_platform = nil
		sel_idx = 1 -- [None]
	end
	
	local t = gui.tags
	t.drop_down_platforms = drop_down_platforms
	gui.tags = t
	
	gui.tags.ui.platform_drop_down.items = drop_down_strings
	gui.tags.ui.platform_drop_down.selected_index = sel_idx
end
function radar_gui_update(gui, radar)
	radar_gui_update_platforms(gui, radar)
	
	gui.tags.ui.mode1.state = radar.read_plat_requests
	gui.tags.ui.mode2.state = radar.read_plat_location
end

script.on_event(defines.events.on_gui_checked_state_changed, radar_gui_checked_changed)
script.on_event(defines.events.on_gui_selection_state_changed, radar_gui_selection_changed)

local function on_close_gui_button(event)
	local player = game.get_player(event.player_index)
	local window = player.gui.screen.hexcoder_entity_gui
	if (window) then
		-- we seemingly can't "consume" the E press when intending to close custom gui
		-- So instead force close inventory that opens if just closed custom window
		--player.opened = nil -- Doesn't work, Has E press not been processed yet?
		
		close_custom_window(player, true)
	end
end

script.on_nth_tick(1, function(event)
	close_invalid_gui()
	
	for _, open_gui in pairs(gui_state) do
		local data = get(open_gui.entity)
		radar_gui_update(open_gui, data)
	end
end)

--]]

local function create_radar_gui(player, entity)
	local window, ui_refs = glib.add(player.gui.screen, default_frame("hexcoder_radar_gui", "Radar Control"))
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
						}
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
						{args = {type = "checkbox", name = "mode1", caption = "Read Platform Request", state=false }},
						{args = {type = "checkbox", name = "mode2", caption = "Read Platform Location", state=false }},
					}
				}
			}
		--}
	}, ui_refs)
	
	
	-- store associated entity in ui
	--local t = window.tags or {}
	--t.entity_id = entity_id = script.register_on_object_destroyed(entity)
	--t.entity_type = "radar"
	--t.ui = ui_refs
	--window.tags = t
	
	local id = script.register_on_object_destroyed(entity)
	
	-- Need to use storage despite having player.opened because player.opened.tags cannot store lua entity, only non-reversible id (?)
	storage.open_guis[player.index] = { gui=window, entity=entity, entity_id=id }
	
	--radar_gui_update(player, entity)
	
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
		if (event.registration_number == gui.entity_id) then
			game.get_player(player_i).opened = nil
			storage.open_guis[player_i] = nil
		end
	end
end)
script.on_nth_tick(6, function(event)
	--_reset()
	for player_i, gui in pairs(storage.open_guis) do
		local player = game.get_player(player_i)
		-- close custom gui once out of reach
		local valid = gui.entity.valid and player.can_reach_entity(gui.entity)
		if (not valid) then
			player.opened = nil
		end
	end
end)

-- reacting to LMB requires custom input(?)
script.on_event("hexcoder_left_click", function(event)
	local player = game.get_player(event.player_index)
	local entity = player.selected -- hovered entity
	local valid = entity and entity.valid and player.can_reach_entity(entity)
	
	if (valid) then
		game.print(">>> on_entity_click ".. entity.name, prnt)
		
		if (entity.type == "radar" and entity.name == "radar") then
			open_custom_entity_gui(player, entity)
		end
	end
end)
