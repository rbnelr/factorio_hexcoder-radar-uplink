local glib = require("__glib__/glib")
local default_frame = require("__glib__/examples/default_frame")
local prnt = {sound=defines.print_sound.never}

function init(event)
	storage.data = {}
end
local gui_state = {}

local _do_reset = nil
function _reset(event)
	if (_do_reset) then _do_reset = false
		storage.silos = nil
		storage.data = nil
		
		init()
	end
end
script.on_init(function(event)
	init()
end)
script.on_load(function(event) -- during dev: reset storage fully to enable iterating without errors
	_do_reset = true
end)

local function register(entity)
	_reset()
	if (entity == nil) then return nil end
	local id = script.register_on_object_destroyed(entity)
	
	local data = storage.data[id]
	if (data) then return data end
	
	if (entity.type == "rocket-silo") then
		game.print("register silo id " .. id .." : ".. entity.name, prnt)
		storage.data[id] = {
			type = "rocket-silo",
			entity = entity,
			mode = "vanilla",
		}
	elseif storage.data[id] == nil then
		game.print("register radar id " .. id .." : ".. entity.name, prnt)
		storage.data[id] = {
			type = "radar",
			entity = entity,
			read_plat_requests = false,
			read_plat_location = false,
			selected_platform = nil,
		}
	end
	return storage.data[id]
end
local function unregister(id)
	_reset()
	if storage.data[id] then
		game.print("on_object_destroyed id " .. id, prnt)
		storage.data[id] = nil
	end
end
local function get(entity)
	_reset()
	if (not entity) then return nil end
	local id = script.register_on_object_destroyed(entity)
	return storage.data[id]
end

-- GUI
local function close_custom_window(player, play_sound)
	local window = player.gui.screen.hexcoder_entity_gui
	if (window) then
		if (play_sound) then
			player.play_sound{ path="hexcoder-radar-close-sound" }
		end
		window.destroy()
		gui_state[player.index] = nil
	end
end

local function on_gui_silo(player, event)
	local data = register(event.entity)
	
	local gui = player.gui.relative.hexcoder_silo_ctrl
	if (not gui) then -- create gui on open
		game.print(">>> open silo gui", prnt)
		
		gui = player.gui.relative.add({
			type = "frame",
			name = "hexcoder_silo_ctrl",
			caption = "Rocket Silo Control",
			direction = "vertical",
			index = 0,
			anchor = {
				gui = defines.relative_gui_type.rocket_silo_gui,
				position = defines.relative_gui_position.right
			}
		})
		
		local frame = gui.add({
			type = "frame",
			name = "hexcoder_silo_ctrl_controls",
			style = "inside_shallow_frame_with_padding",
			direction = "vertical",
		})
		
		frame.add({
			type = "checkbox",
			name = "hexcoder_silo_mode",
			style = "caption_checkbox",
			caption = "Active",
			state = data.mode ~= "vanilla",
		})
	end
end
--local function gui_changed(event)
--	game.print(">>> gui_changed ".. event.element.name)
--	
--	local player = game.get_player(event.player_index)
--	local entity = player.opened
--	local data = get(entity)
--	
--	if (event.element.name == "hexcoder_silo_mode") then
--		if (event.element.state) then data.mode = "read_platform" else data.mode = "vanilla" end
--	end
--end

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
--script.on_event(defines.events.on_gui_checked_state_changed, gui_changed)


---- Custom entity GUI window

--function checked_state_changed(event)
--	local gui = gui_state[event.player_index]
--	local data = get(gui.entity)
--	
--	if     (event.element.name == "radio1") then data.mode = "vanilla"
--	elseif (event.element.name == "radio2") then data.mode = "read_platform" end
--	
--	gui.refs.radio1.state = data.mode == "vanilla"
--	gui.refs.radio2.state = data.mode == "read_platform"
--end
function radar_gui_checked_changed(event)
	local gui = gui_state[event.player_index]
	local radar = get(gui.entity)
	
	if     (event.element.name == "radio1") then radar.read_plat_requests = event.element.state
	elseif (event.element.name == "radio2") then radar.read_plat_location = event.element.state end
end
function radar_gui_selection_changed(event)
	--if (event.element.name == "platform_drop_down") then
		--local gui = gui_state[event.player_index]
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
	
	gui.drop_down_platforms = drop_down_platforms
	
	gui.refs.platform_drop_down.items = drop_down_strings
	gui.refs.platform_drop_down.selected_index = sel_idx
end
function radar_gui_update(gui, radar)
	game.print(serpent.block(gui))
	--radar_gui_update_platforms(gui, radar)
	--
	--gui.refs.mode1.state = radar.read_plat_requests
	--gui.refs.mode2.state = radar.read_plat_location
end

-- TODO: adjust cursor on drag-elements ?
-- TODO: make E/ESC work exactly like in vanilla guis
local function radar_gui_open(player, entity)
	local player_gui = gui_state[player.index]
	local window = player.gui.screen.hexcoder_entity_gui
	
	if (window and player_gui and player_gui.entity ~= entity) then
		game.print(">>> clicked different entity", prnt)
		close_custom_window(player, false)
		window = nil
	end
	
	if (not window) then
		game.print(">>> open radar gui", prnt)
		
		player.opened = nil -- close regular gui
		
		local data = register(entity)
		local refs
		window, refs = glib.add(player.gui.screen, default_frame("hexcoder_entity_gui", "Radar Control"))
		window.force_auto_center()
		
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
		}, refs)
		
		gui_state[player.index] = { gui=window, refs=refs, entity=entity }
		radar_gui_update(gui_state[player.index], data)
		
		player.play_sound{ path="hexcoder-radar-open-sound" }
	end
end

local function close_invalid_gui()
	-- On destroyed entity, close any open guis that are associated with the entity
	-- On player being no longer in reach of entity close gui
	for player_i, open_gui in pairs(gui_state) do
		local player = game.get_player(player_i)
		local valid = open_gui and open_gui.entity.valid and player.can_reach_entity(open_gui.entity)
		if (not valid) then
			game.print(" > close invalid entity : ".. (entity and "entity" or "nil"), prnt)
			close_custom_window(player, false)
		end
	end
end

script.on_event(defines.events.on_gui_checked_state_changed, radar_gui_checked_changed)
script.on_event(defines.events.on_gui_selection_state_changed, radar_gui_selection_changed)

script.on_event("hexcoder_left_click", function(event)
	--game.print(">>> hexcoder_left_click at ".. event.cursor_position.x .." ".. event.cursor_position.y)
	
	--local gui = player.gui.screen.hexcoder_entity_gui
	--if (gui) then gui.destroy() end
	
	--local player = game.get_player(event.player_index)
	--local view_surf = player.surface
	--
	--
	--local entities = view_surf.find_entities_filtered{
	--	position = event.cursor_position,
	--	force = "player", type="radar", name={"radar"}} -- or find_entity
	
	local player = game.get_player(event.player_index)
	local entity = player.selected
	local valid = entity and player.can_reach_entity(entity)
	
	-- on first click on entity  => create gui
	-- on click on same entity, click on GUI or on ground => keep gui open
	-- on click on different entity => close and open different gui
	
	if (valid and entity.type == "radar" and entity.name == "radar") then
		radar_gui_open(player, entity)
	end
end)
local function _close_gui(event)
	--game.print(">>> close_gui ".. event.player_index)
	
	local player = game.get_player(event.player_index)
	local window = player.gui.screen.hexcoder_entity_gui
	if (window) then
		-- we seemingly can't "consume" the E press when intending to close custom gui
		-- So instead force close inventory that opens if just closed custom window
		--player.opened = nil -- Doesn't work, Has E press not been processed yet?
		
		close_custom_window(player, true)
	end
end
script.on_event("hexcoder_close_menu", _close_gui)
script.on_event("hexcoder_close_escape", _close_gui)

-- E can close our custom gui, but we wan't press -> close_gui press again -> open character inventory, this does not work
-- glib default_frame still does not show finger cursor when over draggable widget part of title bar

script.on_event(defines.events.on_object_destroyed, function(event)
	unregister(event.registration_number)
	close_invalid_gui()
end)

script.on_nth_tick(1, function(event)
	close_invalid_gui()
	
	for _, open_gui in pairs(gui_state) do
		local data = get(open_gui.entity)
		radar_gui_update(open_gui, data)
	end
	
	for _, data in pairs(storage.data) do
		if (data.read_plat_requests or data.read_plat_location) then
			
		end
	end
end)

-- debug tick
script.on_nth_tick(60*2, function(event)
	for p=1,#game.players do
		local player = game.players[p]
		local entity = player.opened
		local data = entity and entity.type == "rocket-silo" and get(entity)
		if (data and data.mode ~= "vanilla") then
			local gui = player.gui.relative.hexcoder_silo_ctrl
			
			game.print("> open gui for " .. data.id .." : ".. entity.name .." => mode= ".. data.mode)
			if (entity.surface.planet) then
				for _, platf in pairs(entity.surface.planet.get_space_platforms(entity.force)) do
					game.print(" > platform ".. platf.name)
				end
			end
		end
	end
end)

