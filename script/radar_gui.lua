---@class OpenGui
---@field refs table
---@field data RadarData -- Hold reference to data in storage for opened radar, or independent data if opening gui on ghost entity (created from tags)
---@field drop_down_platforms platform_index[]
---@field drop_down_channels channel_id[]

local radar_channels = require("script.radar_channels")
local radars = require("script.radars")
require("script.myutil")

local M = {}

---@param gui OpenGui
---@param data RadarData
local function radar_gui_update_channels(gui, data)
	-- In theory this only needs to be updated once per tick, but each player can only have one gui open anyway
	-- duplicates work in multiplayer, but in theory players could each have different forces!
	local drop_down_strings = {"[None]"}
	local drop_down_channels = {0}
	local counter = 2 -- next channel in list
	local sel_idx = nil
	
	for id, ch in pairs(storage.channels.map) do
		drop_down_strings[counter] = ch.name
		drop_down_channels[counter] = ch.id
		
		if data.S.selected_channel == id then
			sel_idx = counter
		end
		counter = counter+1
	end
	
	drop_down_strings[counter] = "[Create new channel]"
	drop_down_channels[counter] = -1
	
	if not sel_idx then
		data.S.selected_channel = 0
		sel_idx = 1 -- [None]
	end
	
	gui.drop_down_channels = drop_down_channels
	gui.refs.ch_drop_down.items = drop_down_strings
	gui.refs.ch_drop_down.selected_index = sel_idx
	
	local ch = storage.channels.map[data.S.selected_channel]
	gui.refs.ch_name.text = ch and ch.name or ""
	gui.refs.ch_interplanetary.state = ch and ch.is_interplanetary and storage.settings.allow_interpl or false
	
	local can_edit = ch ~= nil and ch.id > 1 -- can't edit [Global] channel!
	gui.refs.ch_name.enabled = can_edit
	gui.refs.ch_delete.enabled = can_edit
	gui.refs.ch_interplanetary.enabled = can_edit and storage.settings.allow_interpl
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
			if radars.platform_valid(platf) then
				local suffix = ""
				--if not radars.platform_valid(platf) then suffix = " (Not fully built)"
				--else
				if platf.scheduled_for_deletion ~= 0 then suffix = " [color=#f00000][virtual-signal=signal-trash-bin] (Scheduled for deletion)[/color]" end
				
				drop_down_strings[counter] = platf.name..suffix
				drop_down_platforms[counter] = platf.index
				
				-- if platform still found in list (by identity, not name), keep it selected, if not select [None]
				if data.S.selected_platform == platf.index then
					sel_idx = counter
				end
				counter = counter+1
			end
		end
	end
	
	if not sel_idx then -- selected_platform not found, it could have been deleted
		data.S.selected_platform = nil
		sel_idx = 1 -- [None]
	end
	
	gui.drop_down_platforms = drop_down_platforms
	gui.refs.pl_drop_down.items = drop_down_strings
	gui.refs.pl_drop_down.selected_index = sel_idx
end

-- init ui from data
---@param gui OpenGui
---@param data RadarData
local function radar_update_gui(gui, data)
	radar_gui_update_channels(gui, data)
	radar_gui_update_platforms(gui, data)
	
	local refs = gui.refs
	local S = gui.data.S
	
	refs.mode_comms.state = (S.mode or "comms") == "comms"
	refs.mode_platforms.state = (S.mode or "comms") == "platforms"
	
	refs.comms_pane.visible = refs.mode_comms.state
	refs.platforms_pane.visible = refs.mode_platforms.state
	
	local std = S.read_mode == "std" and S.read or nil
	local raw = S.read_mode == "raw" and S.read or nil
	
	refs.pl_readStd.state = S.read_mode ~= "raw"
	refs.pl_readRaw.state = S.read_mode == "raw"
	
	refs.pl_std.visible = refs.pl_readStd.state
	refs.pl_raw.visible = refs.pl_readRaw.state
	
	for k,v in pairs(std or radars.radar_defaults.pl_std) do
		refs["pl_read"..k.."R"].state = v[1]
		refs["pl_read"..k.."G"].state = v[2]
	end
	for k,v in pairs(raw or radars.radar_defaults.pl_raw) do
		refs["pl_readRaw"..k.."R"].state = v[1]
		refs["pl_readRaw"..k.."G"].state = v[2]
	end
	
	-- radar_gui_update_platforms can reset selected_platform
	-- this causes a radar refresh every time the gui is opened, which is probably a good idea anywy
	radars.refresh_radar(data)
end

-- update data from ui
script.on_event(defines.events.on_gui_checked_state_changed, function(event)
	--game.print("on_gui_checked_state_changed: ".. serpent.block(event))
	local gui = storage.open_guis[event.player_index]
	if not gui then return end
	local refs = gui.refs
	local data = gui.data
	-- build new settings to avoid storing settings not relevant to current mode
	-- NOTE: this means keeping all settings while gui is open (stored in gui state)
	--  but closing the gui resets settings that are in hidden panes
	local S = { mode = data.S.mode or "comms" }
	
	if refs.mode_platforms.state then S.mode = "platforms" end
	if     event.element.name == "mode_comms" then S.mode = "comms"
	elseif event.element.name == "mode_platforms" then S.mode = "platforms" end
	refs.mode_comms.state = S.mode == "comms"
	refs.mode_platforms.state = S.mode == "platforms"
	
	if S.mode == "platforms" then
		S.selected_platform = gui.drop_down_platforms[gui.refs.pl_drop_down.selected_index]
		
		local raw = refs.pl_readRaw.state
		if     event.element.name == "pl_readStd" then raw = false
		elseif event.element.name == "pl_readRaw" then raw = true end
		refs.pl_readStd.state = raw == false
		refs.pl_readRaw.state = raw == true
		
		S.read_mode = raw and "raw" or "std"
		local state = {}
		if raw == false then
			for k,_ in pairs(radars.radar_defaults.pl_std) do
				state[k] = { refs["pl_read"..k.."R"].state,
				             refs["pl_read"..k.."G"].state }
			end
		else
			for k,_ in pairs(radars.radar_defaults.pl_raw) do
				state[k] = { refs["pl_readRaw"..k.."R"].state,
				             refs["pl_readRaw"..k.."G"].state }
			end
		end
		S.read = state
		
		refs.pl_std.visible = S.read_mode == "std"
		refs.pl_raw.visible = S.read_mode == "raw"
	else
		S.selected_channel = gui.drop_down_channels[gui.refs.ch_drop_down.selected_index]
		
		local ch = storage.channels.map[S.selected_channel]
		if ch then
			ch.is_interplanetary = refs.ch_interplanetary.state
			radar_channels.update_is_interplanetary(ch.id)
		end
	end
	
	refs.comms_pane.visible = refs.mode_comms.state
	refs.platforms_pane.visible = refs.mode_platforms.state
	
	data.S = S
	radars.refresh_radar(data)
end)
script.on_event(defines.events.on_gui_selection_state_changed, function(event)
	--game.print("on_gui_selection_state_changed: ".. serpent.block(event))
	local gui = storage.open_guis[event.player_index]
	if not gui then return end
	local data = gui.data
	
	if event.element.name == "pl_drop_down" then
		data.S.selected_platform = gui.drop_down_platforms[event.element.selected_index]
		
		radar_gui_update_platforms(gui, data)
		
		radars.refresh_radar(data)
	elseif event.element.name == "ch_drop_down" then
		data.S.selected_channel = gui.drop_down_channels[event.element.selected_index]
		
		if data.S.selected_channel == -1 then
			data.S.selected_channel = radar_channels.create_new_channel().id
		end
		
		radar_gui_update_channels(gui, data)
		
		radars.refresh_radar(data)
	end
	
end)
script.on_event(defines.events.on_gui_click, function(event)
	local gui = storage.open_guis[event.player_index]
	if not gui then return end
	--game.print("on_gui_click: ".. serpent.block(event))
	if event.element.name == "hexcoder_radar_uplink-window_close_button" then
		game.get_player(event.player_index).opened = nil
	elseif event.element.name == "ch_delete" then
		local data = gui.data
		
		local ch = storage.channels.map[data.S.selected_channel]
		if ch then
			radar_channels.destroy_channel(data.S.selected_channel)
		end
		
		radar_gui_update_channels(gui, data)
	end
end)
script.on_event(defines.events.on_gui_confirmed, function(event)
	local gui = storage.open_guis[event.player_index]
	if not gui then return end
	--game.print("on_gui_confirmed: ".. serpent.block(event))
	if event.element.name == "ch_name" then
		local refs = gui.refs
		local data = gui.data
		
		local ch = storage.channels.map[data.S.selected_channel]
		if ch then
			ch.name = refs.ch_name.text
		end
		
		radar_gui_update_channels(gui, data)
	end
end)

---@param player LuaPlayer
---@param entity LuaEntity
---@return LuaGuiElement
local function create_radar_gui(player, entity)
	local comms_desc = {"tooltip.hexcoder_radar_uplink-comms_mode_desc"}
	local platforms_desc = {"tooltip.hexcoder_radar_uplink-platforms_mode_desc"}
	
	local status_desc = {"tooltip.hexcoder_radar_uplink-status_desc"}
	local request_unful_req_desc = {"tooltip.hexcoder_radar_uplink-request_unful_req_desc"}
	local request_req_desc = {"tooltip.hexcoder_radar_uplink-request_req_desc"}
	local request_otw_desc = {"tooltip.hexcoder_radar_uplink-request_otw_desc"}
	local request_inv_desc = {"tooltip.hexcoder_radar_uplink-request_inv_desc"}
	
	local tick2 = {"tooltip.hexcoder_radar_uplink-tick2_suffix"}
	
	local function circuit_enable(name, caption, tooltip, tooltip_suffix)
		return gui_hflow{}:add{
			GUI{type="label", caption=caption, tooltip={"", tooltip, "\n", tooltip_suffix}},
			GUI{type="empty-widget", style={horizontally_stretchable=true}},
			GUI{type="checkbox", name=name.."R", caption={"gui-network-selector.red-label"}, state=false},
			GUI{type="checkbox", name=name.."G", caption={"gui-network-selector.green-label"}, state=false},
		}
	end
	
	local config_pane = gui_vpane("config_pane"):add{
		GUI{type="label", caption="Operation mode", style="caption_label"},
		GUI{type="radiobutton", name="mode_comms", caption="Comms", state=false, tooltip=comms_desc},
		GUI{type="radiobutton", name="mode_platforms", caption="Platforms", state=false, tooltip=platforms_desc},
	}
	local comms_pane = gui_vpane("comms_pane"):add{
		gui_hflow{}:add{
			GUI{type="label", caption="Channel", style={base="caption_label", margin={4,6,0,0}}},
			GUI{type="drop-down", name="ch_drop_down", items={""}, selected_index=1 },
		},
		GUI{type="line", style={margin={8,0,8,0}}},
		gui_hflow{style={bottom_margin=8}}:add{
			GUI{type="label", caption="Name", style={margin={4,6,0,0}}},
			GUI{type="textfield", name="ch_name", text="", tooltip="Rename channel (connected radars stay connected)" }, -- default height 28
			GUI{type="sprite-button", name="ch_delete", style={base="red_button", size={28, 28}, padding={0,0,0,0}},
				sprite="utility/trash", tooltip="Delete channel (universally for all radars)" },
		},
		GUI{type="checkbox", name="ch_interplanetary", caption="Interplanetary", state=false,
			tooltip="Does this channel connect to all surfaces?\n(Can be disabled in settings)" },
	}
	local platforms_pane = gui_vpane("platforms_pane"):add{
		gui_hflow{}:add{
			GUI{type="label", caption="Platform", style={base="caption_label", margin={4,6,0,0}}},
			GUI{type="drop-down", name="pl_drop_down", items={""}, selected_index=1 },
		},
		GUI{type="line", style={margin={8,0,8,0}}},
		gui_hflow{style={bottom_margin=6, horizontal_spacing=20}}:add{
			GUI{type="radiobutton", name="pl_readStd", caption="Standard", state=false, tooltip="Standard read mode (2 tick delay)"},
			GUI{type="radiobutton", name="pl_readRaw", caption="Raw",      state=false, tooltip="Raw read mode (Interplanetary reads possible, 1 tick delay)"},
		},
		gui_vflow{name="pl_std"}:add{
			circuit_enable("pl_readSta", "Read platform status",               status_desc,tick2),
			circuit_enable("pl_readReq", "Read platform unfulfilled requests", request_unful_req_desc,tick2),
		},
		gui_vflow{name="pl_raw"}:add{
			circuit_enable("pl_readRawSta", "Read platform status",       status_desc,tick2),
			circuit_enable("pl_readRawReq", "Read platform requests",     request_req_desc,tick2),
			circuit_enable("pl_readRawOtw", "Read platform 'on the way'", request_otw_desc,tick2),
			circuit_enable("pl_readRawInv", "Read platform inventory",    request_inv_desc,tick2),
		}
	}
	
	local window, refs = gui_default_frame("hexcoder_radar_uplink", "Radar circuit connection", {
		gui_hflow{style={natural_width=420, horizontal_spacing=12}}:add{
			config_pane,
			comms_pane,
			platforms_pane
		}
	}):add_to(player.gui.screen)
	window.force_auto_center()
	
	local data = radars.init_radar(entity)
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

return M
