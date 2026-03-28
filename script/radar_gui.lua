---@class OpenGui
---@field refs table
---@field data RadarData
---@field drop_down_platforms platform_index[]

local glib = require("__glib__/glib")
local default_frame = require("__glib__/examples/default_frame")
local radar_channels = require("script.radar_channels")
local radars = require("script.radars")

local handlers = {}
local M = {}

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
			if not radars.platform_valid(platf) then name = name.." (Not fully built)"
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
	radars.refresh_radar(data)
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
	
	radars.refresh_radar(data)
	
	if event.element.name == "mode1" or event.element.name == "mode2" then
		radar_channels.update_radar_channel(data.entity)
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
	radars.refresh_radar(data)
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
	local data = radars.init_radar(entity)
	
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

---- custom entity gui
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
function M.tick_gui(player, gui)
	-- close custom gui once out of reach
	if not can_open_entity_gui(player, gui.data.entity) then
		_skip_closing_sound = true
		player.opened = nil
		_skip_closing_sound = nil
	end
end

glib.register_handlers(handlers)
return M
