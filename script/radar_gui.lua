---@class OpenGui
---@field refs table
---@field data RadarData Holds reference to data in storage for opened radar, or independent data if opening gui on ghost entity (created from tags)
---@field planet LuaPlanet? The planet the radar is on
---@field sel_items LuaSpacePlatform[]|nil

local radars = require("script.radars")
local radar_channels = require("script.radar_channels")
local platforms = require("script.platforms")
require("script.myutil")

local M = {}

local MODES
local READ_MODES

---@param gui OpenGui
---@param data RadarData
local function gui_update_channels(gui, data)
	-- In theory this only needs to be updated once per tick, but each player can only have one gui open anyway
	-- duplicates work in multiplayer, but in theory players could each have different forces!
	local drop_down_strings = {"[None]"}
	local drop_down_channels = {0}
	local counter = 2 -- next channel in list
	local sel_idx = 1
	
	for id, ch in pairs(storage.channels.map) do
		drop_down_strings[counter] = ch.name
		drop_down_channels[counter] = ch.id
		
		if data.S.selected == id then
			sel_idx = counter
		end
		counter = counter+1
	end
	
	drop_down_strings[counter] = "[Create new channel]"
	drop_down_channels[counter] = -1
	
	gui.drop_down_channels = drop_down_channels
	gui.refs.ch_drop_down.items = drop_down_strings
	gui.refs.ch_drop_down.selected_index = sel_idx
	
	local ch = storage.channels.map[data.S.selected]
	gui.refs.ch_name.text = ch and ch.name or ""
	gui.refs.ch_interplanetary.state = ch and ch.is_interplanetary and ALLOW_INTERPL or false
	
	local can_edit = ch ~= nil and ch.id > 1 -- can't edit [Global] channel!
	gui.refs.ch_name.enabled = can_edit
	gui.refs.ch_delete.enabled = can_edit
	gui.refs.ch_interplanetary.enabled = can_edit and ALLOW_INTERPL
end

---@param gui OpenGui
---@param data RadarData
local function gui_update_platform_list(gui, data)
	local list = radars.get_platform_list(data)
	
	local gui_names = { "[color=#a0a0a0][font=default-small]ID    [/font][/color][None]" }
	local gui_items = { nil }
	local sel_idx = 1
	local sel = data.S.selected_platform
	
	for idx, plat in ipairs(list) do
		local pl = plat.entity
		local suffix = ""
		if pl.scheduled_for_deletion ~= 0 then suffix = "[color=#f00000][virtual-signal=signal-trash-bin] (Scheduled for deletion)[/color]" end
		
		gui_names[idx+1] = string.format("[color=#a0a0a0][font=default-small]%2d    [/font][/color]%s %s", pl.index, pl.name, suffix)
		gui_items[idx+1] = pl
		
		if sel == pl then
			sel_idx = idx+1
		end
	end
	
	if sel_idx <= 1 then
		if sel and sel.valid then
			sel_idx = #gui_names+1
			gui_names[sel_idx] = string.format("[color=#a0a0a0][font=default-small]%2d    [/font][/color] [color=#b0b0b0]%s (Not in orbit)[/color]", sel.index, sel.name)
			gui_items[sel_idx] = sel
		end
	end
	
	gui.refs.sel_list.items = gui_names
	gui.refs.sel_list.selected_index = sel_idx
	gui.sel_items = gui_items
end

---@param gui OpenGui
---@param refs GuiRefs
local function gui_update_vis_en(gui, refs)
	refs.sel_orbit_only.enabled = gui.planet ~= nil
	
	local mode = update_radiobutton(refs, MODES)
	
	--refs.comms_pane.visible = mode == "comms"
	refs.pl_config.visible = mode == "platforms"
	
	if mode == "comms" then
	else
		--local read_mode = update_radiobutton(refs, READ_MODES)
		--refs.pl_std.visible = read_mode == "std"
		--refs.pl_raw.visible = read_mode == "raw"
		
		local raw = S.read_mode == "right"
		refs.pl_std.visible = read_mode == "std"
		refs.pl_raw.visible = read_mode == "raw"
	end
	
	refs.dynR.enabled = refs.dyn_enable.state
	refs.dynG.enabled = refs.dyn_enable.state
	refs.dyn_text.visible = refs.dyn_enable.state
end

-- init ui from data
---@param gui OpenGui
---@param data RadarData
local function radar2gui(gui, data)
	--radar_gui_update_channels(gui, data)
	gui_update_platform_list(gui, data)
	
	local refs = gui.refs
	local S = gui.data.S
	
	refs.sel_orbit_only.state = (gui.planet and S.sel_orbit_only) == true
	
	refs.mode_comms.state = (S.mode or "comms") == "comms"
	refs.mode_platforms.state = S.mode == "platforms"
	
	refs.dyn_enable.state = S.dyn or false
	local dyn = S.dyn or radars.radar_defaults.dyn
	refs["dynR"].state = dyn.R
	refs["dynG"].state = dyn.G
	
	if S.mode == "comms" then
	else
		--local std = S.read_mode == "std" and S.read or nil
		--local raw = S.read_mode == "raw" and S.read or nil
		
		local raw = S.read_mode == "right"
		--local raw = S.read_mode == "raw" and S.read or nil
		
		refs.pl_mode.state = raw and "right" or "left"
		refs.pl_readStd.state = not raw
		refs.pl_readRaw.state = raw
		
		if not raw then
			for k,v in pairs(radars.radar_defaults.pl_std) do
				refs["pl_read"..k.."R"].state = v.R
				refs["pl_read"..k.."G"].state = v.G
			end
		else
			for k,v in pairs(radars.radar_defaults.pl_raw) do
				refs["pl_readRaw"..k.."R"].state = v.R
				refs["pl_readRaw"..k.."G"].state = v.G
			end
		end
	end
	
	gui_update_vis_en(gui, refs)
	
	-- radar_gui_update_platforms can reset selected_platform
	-- this causes a radar refresh every time the gui is opened, which is probably a good idea anywy
	radars.refresh_radar(data)
end

-- global
function refresh_all_guis()
	for _, gui in pairs(storage.open_guis) do
		--if gui.planet and gui.planet.prototype == planet and gui.data.S..state then
		radar2gui(gui, gui.data)
	end
end

-- update data from ui
script.on_event(defines.events.on_gui_checked_state_changed, function(event)
	--game.print("on_gui_checked_state_changed: ".. serpent.block(event))
	local gui = storage.open_guis[event.player_index]
	if not gui then return end
	local refs = gui.refs
	
	local mode = update_radiobutton(refs, MODES, event.element.name)
	
	local S = { mode=mode }
	if mode == "comms" then
		--S.selected_channel = gui.drop_down_channels[gui.refs.ch_drop_down.selected_index]
		--
		--local ch = storage.channels.map[S.selected_channel]
		--if ch then
		--	ch.is_interplanetary = refs.ch_interplanetary.state
		--	radar_channels.update_is_interplanetary(ch.id)
		--end
	else
		S.sel_orbit_only = (gui.planet and refs.sel_orbit_only.state) == true
		S.dyn = refs.dyn_enable.state and { R=refs.dynR.state, G=refs.dynG.state } or nil
		
		--local read_mode = update_radiobutton(refs, READ_MODES, event.element.name)
		--
		--local prefix = read_mode == "std" and "pl_read" or "pl_readRaw"
		--local read = {}
		--for k,_ in pairs(radars.radar_defaults[prefix]) do ---@diagnostic disable-line
		--	read[k] = { R=refs[prefix..k.."R"].state,
		--	            G=refs[prefix..k.."G"].state }
		--end
		--S.read_mode = read_mode
		--S.read = read
	end
	
	gui.data.S = S
	
	gui_update_vis_en(gui, refs)
	gui_update_platform_list(gui, gui.data)
	
	radars.refresh_radar(gui.data)
end)
script.on_event(defines.events.on_gui_selection_state_changed, function(event)
	--game.print("on_gui_selection_state_changed: ".. serpent.block(event))
	local gui = storage.open_guis[event.player_index]
	if not gui then return end
	local data = gui.data
	
	if event.element.name == "sel_list" then
		data.S.selected_platform = gui.sel_items[gui.refs.sel_list.selected_index]
		
		radar2gui(gui, data)
	elseif event.element.name == "ch_drop_down" then
		--data.S.selected_channel = gui.drop_down_channels[event.element.selected_index]
		--
		--if data.S.selected_channel == -1 then
		--	data.S.selected_channel = radar_channels.create_new_channel().id
		--end
		--
		--radar_gui_update_channels(gui, data)
	end
	
	radars.refresh_radar(data, true)
end)
script.on_event(defines.events.on_gui_click, function(event)
	local gui = storage.open_guis[event.player_index]
	if not gui then return end
	--game.print("on_gui_click: ".. serpent.block(event))
	if event.element.name == "hexcoder_radar_uplink-window_close_button" then
		M.force_close_gui(event.player_index)
	elseif event.element.name == "ch_delete" then
		--local data = gui.data
		--
		--local ch = storage.channels.map[data.S.selected_channel]
		--if ch then
		--	radar_channels.destroy_channel(data.S.selected_channel)
		--end
		
		--radar_gui_update_channels(gui, data)
	end
end)
script.on_event(defines.events.on_gui_confirmed, function(event)
	local gui = storage.open_guis[event.player_index]
	if not gui then return end
	local refs = gui.refs
	local data = gui.data
	
	--game.print("on_gui_confirmed: ".. serpent.block(event))
	if event.element.name == "dyn_text" then
		data.S.dyn_text = refs.dyn_text.text
		radars.refresh_radar(gui.data, true)
	elseif event.element.name == "ch_name" then
		
		--local ch = storage.channels.map[data.S.selected]
		--if ch then
		--	ch.name = refs.ch_name.text
		--end
		
		--radar_gui_update_channels(gui, data)
	end
end)

---@return GuiDef
local function get_window_def()
	local comms_desc = {"tooltip.hexcoder_radar_uplink-read_comms_mode"}
	local platforms_desc = {"tooltip.hexcoder_radar_uplink-read_platforms_mode"}
	
	local status_desc = {"tooltip.hexcoder_radar_uplink-read_status"}
	local unful_req_desc = {"tooltip.hexcoder_radar_uplink-read_unful_req"}
	local req_desc = {"tooltip.hexcoder_radar_uplink-read_req"}
	local otw_desc = {"tooltip.hexcoder_radar_uplink-read_otw"}
	local inv_desc = {"tooltip.hexcoder_radar_uplink-read_inv"}
	local inv_slots_desc = {"tooltip.hexcoder_radar_uplink-read_inv_slots"}
	
	local tick2 = {"tooltip.hexcoder_radar_uplink-tick2_suffix"}
	
	local function circuit_enable(name, caption, tooltip, tooltip_suffix)
		return gui_hflow{}:add{
			GUI{type="label", caption=caption, tooltip={"", tooltip, "\n", tooltip_suffix}},
			GUI{type="empty-widget", style={horizontally_stretchable=true}},
			GUI{type="checkbox", name=name.."R", caption={"gui-network-selector.red-label"}, state=false},
			GUI{type="checkbox", name=name.."G", caption={"gui-network-selector.green-label"}, state=false},
		}
	end
	
	local mode_pane = gui_hflow{style={horizontal_spacing=20}}:add{
		GUI{type="label", caption="Operation mode", style={base="subheader_caption_label"}},
		GUI{type="empty-widget", style={horizontally_stretchable=true}},
		GUI{type="radiobutton", name="mode_comms", caption="Comms", state=false, tooltip=comms_desc, style={top_margin=3}},
		GUI{type="radiobutton", name="mode_platforms", caption="Platforms", state=false, tooltip=platforms_desc, style={top_margin=3}},
		GUI{type="empty-widget", style={horizontally_stretchable=true}},
	}
	MODES = {
		["mode_comms"]="comms",
		["mode_platforms"]="platforms",
	}
	
	local list_pane = {
		GUI{type="frame", direction="horizontal", style="subheader_frame"}:add{
			GUI{type="label", caption="Selection", style={base="subheader_caption_label", bottom_margin=5}},
			GUI{type="empty-widget", style={horizontally_stretchable=true}},
			GUI{type="checkbox", name="sel_orbit_only", caption="Only in Orbit", state=false, style={right_margin=8}},
		},
		GUI{type="list-box", name="sel_list", style="list_box_under_subheader", items={""}, selected_index=1 },
	}
	
	--local comms_pane = gui_vpane("comms_pane", {vertically_stretchable=true}):add{
	--	gui_hflow{}:add{
	--		GUI{type="label", caption="Channel", style={base="caption_label", margin={4,6,0,0}}},
	--		GUI{type="drop-down", name="ch_drop_down", items={""}, selected_index=1 },
	--	},
	--	GUI{type="line", style={margin={8,0,8,0}}},
	--	gui_hflow{style={bottom_margin=8}}:add{
	--		GUI{type="label", caption="Name", style={margin={4,6,0,0}}},
	--		GUI{type="textfield", name="ch_name", text="", tooltip="Rename channel (connected radars stay connected)" }, -- default height 28
	--		GUI{type="sprite-button", name="ch_delete", style={base="red_button", size={28, 28}, padding={0,0,0,0}},
	--			sprite="utility/trash", tooltip="Delete channel (universally for all radars)" },
	--	},
	--	GUI{type="checkbox", name="ch_interplanetary", caption="Interplanetary", state=false,
	--		tooltip="Does this channel connect to all surfaces?\n(Can be disabled in settings)" },
	--}
	
	local dyn_hint = "    [font=default-small]via [virtual-signal=signal-number-sign][virtual-signal=signal-P][virtual-signal=signal-X][/font]"
	-- Can also use GUI{type="sprite", sprite="virtual-signal/signal-X", resize_to_sprite=true, style={stretch_image_to_widget_size=true, maximal_width=16, maximal_height=16, top_margin=4}},
	
	local dyn_pane = gui_vflow{name="dyn_pane", style={vertical_spacing=10}}:add{
		gui_hflow{}:add{
			GUI{type="checkbox", name="dyn_enable", caption="Dynamic Select"..dyn_hint, state=false,
			    style={base="caption_checkbox"}, tooltip={"tooltip.hexcoder_radar_uplink-dyn_enable"}},
			GUI{type="empty-widget", style={horizontally_stretchable=true}},
			GUI{type="checkbox", name="dynR", caption={"gui-network-selector.red-label"}, state=false},
			GUI{type="checkbox", name="dynG", caption={"gui-network-selector.green-label"}, state=false},
		},
		GUI{type="textfield", name="dyn_text", text="", tooltip={"tooltip.hexcoder_radar_uplink-dyn_name"}, style="stretchable_textfield"},
	}
	
	local pl_config = gui_vflow{name="pl_config", style={vertical_spacing=20}}:add{
		gui_hflow{style={horizontal_spacing=50}}:add{
			--GUI{type="radiobutton", name="pl_readStd", caption="Standard", state=false, tooltip="Standard read mode"},
			--GUI{type="radiobutton", name="pl_readRaw", caption="Raw",      state=false, tooltip="Raw read mode (Interplanetary reads possible)"},
			GUI{type="switch", name="pl_mode", switch_state="left", allow_none_state=false,
				left_label_caption="Standard", left_label_tooltip="Standard read mode",
				right_label_caption="Raw", right_label_tooltip="Raw read mode (Interplanetary reads possible)"},
		},
		gui_vflow{name="pl_std"}:add{
			circuit_enable("pl_readSta", "Read status",               status_desc,tick2),
			circuit_enable("pl_readReq", "Read unfulfilled requests", unful_req_desc,tick2),
		},
		gui_vflow{name="pl_raw"}:add{
			circuit_enable("pl_readRawSta", "Read status",               status_desc,tick2),
			circuit_enable("pl_readRawReq", "Read requests",             req_desc,tick2),
			circuit_enable("pl_readRawOtw", "Read on the way",           otw_desc,tick2),
			circuit_enable("pl_readRawInv", "Read inventory",            inv_desc,tick2),
			circuit_enable("pl_readRawInvSlots", "Read inventory slots", inv_slots_desc,tick2),
		}
	}
	--READ_MODES = {
	--	["pl_std"]="std",
	--	["pl_raw"]="raw",
	--}
	
	return gui_default_frame("hexcoder_radar_uplink", "Radar circuit connection", {
		gui_hflow{style={minimal_height=400, natural_height=400, maximal_height=700, horizontal_spacing=12}}:add{
			GUI{type="frame", name="list_pane", direction="vertical",
			    style={base="inside_deep_frame", natural_width=250, vertically_stretchable=true}}:add(list_pane),
			gui_vflow{style={vertical_spacing=10}}:add{
				gui_vpane("mode_pane", {padding={7,5,9,5}}):add{
					mode_pane
				},
				gui_vpane("config_pane", {natural_width=350, vertically_stretchable=true, padding={8,10,10,10}}):add{
					dyn_pane,
					GUI{type="line", style={margin={8,0,8,0}}},
					pl_config
				}
			}
		},
	})
end
local window_def = get_window_def()

---@param player_index player_index
---@param player LuaPlayer
---@param entity LuaEntity
---@return LuaGuiElement
local function create_radar_gui(player_index, player, entity)
	M.force_close_gui(player_index)
	
	local window, refs = window_def:add_to(player.gui.screen)
	window.force_auto_center()
	
	local data = radars.init_radar(entity)
	local gui = { refs=refs, data=data, planet=entity.surface.planet }
	storage.open_guis[player_index] = gui
	
	radar2gui(gui, data)
	
	return window
end

---@param player_index player_index
function M.force_close_gui(player_index)
	local player = game.get_player(player_index)
	if player then
		local existing = player.gui.screen["hexcoder_radar_uplink"]
		if existing then
			player.opened = nil
			
			existing.destroy() -- going into /editor can cause player.opened = nil but gui to still exist
		end
	end
	
	storage.open_guis[player_index] = nil
end

---- custom entity gui
local _skip_closing_sound = nil -- ugly state passed between event that trigger other event directly, I don't think this can desync
local function can_open_entity_gui(player, entity)
	return entity.valid and player.force == entity.force and player.can_reach_entity(entity)
end
-- TODO: enable configuring ghosts? If that is done, can I keep settings on building correctly? via tags? will gui stay open during build process?
script.on_event("hexcoder_radar_uplink-open-gui", function(event) ---@cast event EventData.CustomInputEvent
	--game.print("open-gui: ".. serpent.block(event))
	if not event.selected_prototype then
		return
	end
	
	local player = game.get_player(event.player_index) ---@cast player -nil
	local entity = player.selected -- hovered entity or ghost
	
	if not radars.is_radar(entity) then return end
	---@cast entity -nil
	
	local free_cursor = not (player.cursor_stack.valid_for_read or player.cursor_ghost or player.cursor_record)
	
	if free_cursor and can_open_entity_gui(player, entity) then
		-- keep gui open if exact entity already open
		local gui = player.opened and storage.open_guis[player.index]
		if gui and entity.unit_number == gui.data.id then return end
		
		script.register_on_object_destroyed(player)
		
		-- close regular or custom gui first
		_skip_closing_sound = true
		player.opened = nil
		_skip_closing_sound = nil
		
		-- guis in player.opened will close via E and Escape automatically
		player.opened = create_radar_gui(event.player_index, player, entity)
		
		player.play_sound{ path="hexcoder_radar_uplink-open-sound" }
	end
end)
-- called on player.opened=nil, on window close button, on E or Escape press
script.on_event(defines.events.on_gui_closed, function(event)
	if event.element and event.element.name == "hexcoder_radar_uplink" then
		M.force_close_gui(event.player_index)
		
		if not _skip_closing_sound then
			local player = game.get_player(event.player_index) ---@cast player -nil
			player.play_sound{ path="hexcoder_radar_uplink-close-sound" }
		end
	end
end)
script.on_event(defines.events.on_player_controller_changed, function(event)
	-- this fixes 'going into /editor can cause player.opened = nil but gui to still exist'
	-- on_gui_closed seems to trigger first, so sound still plays, so don't need to actually check controller
	M.force_close_gui(event.player_index)
end)

---@param player LuaPlayer
---@param gui OpenGui
function M.tick_gui(player, gui)
	-- close custom gui once out of reach
	if can_open_entity_gui(player, gui.data.entity) then
		--radar_gui_update_platform_list(gui, gui.data)
		-- TODO: update from platform list changes or radar dynamic selection instead
	else
		_skip_closing_sound = true
		player.opened = nil
		_skip_closing_sound = nil
	end
end

return M