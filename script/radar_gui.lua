---@class OpenGui
---@field refs GuiRefs
---@field data RadarData Holds reference to data in storage for opened radar, or independent data if opening gui on ghost entity (created from tags)
---@field sel_items LuaSpacePlatform[]|nil

local radars = require("script.radars")
local radar_channels = require("script.radar_channels")
require("script.myutil")

local M = {}

local MODES

--[[
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
]]

-- build platform list depending on mode and settings for gui, including what is currently selected
-- does not update radar! (data -> gui)
---@param gui OpenGui
---@param data RadarData
local function gui_update_platform_list(gui, data)
	local list = radars.get_platform_list(data)
	
	local gui_names = { "[color=#a0a0a0][font=default-small]ID    [/font][None][/color]" }
	local gui_items = { nil }
	local idx = 2 -- next insert index
	local sel_idx = nil
	local sel = data.S.selected_platform
	
	for _, plat in pairs(list) do
		local pl = plat.entity
		if pl and pl.valid then -- platforms in list should not be invalid, but check anyway
			local suffix = ""
			if pl.scheduled_for_deletion ~= 0 then suffix = " [color=#f00000](Scheduled for deletion)[/color]" end
			
			gui_names[idx] = string.format("[color=#a0a0a0][font=default-small]%2d    [/font][/color]%s%s", pl.index, pl.name, suffix)
			gui_items[idx] = pl
			
			if sel == pl then
				sel_idx = idx
			end
			idx = idx + 1
		end
	end
	
	if sel_idx == nil then -- sel not in list, either nothing selected, platform deleted or not in orbit
		if sel == nil then
			sel_idx = 1 -- select [None] in ui
		else
			-- add fake entry at the end to show what was selected despite not showing in ui, as the selection stays
			sel_idx = idx
			gui_items[idx] = sel
			if sel.valid then
				-- Not in list because not in orbit
				gui_names[idx] = string.format("[color=#a0a0a0][font=default-small]%2d    [/font][/color] [color=#b0b0b0]%s (Not in orbit)[/color]", sel.index, sel.name)
			else
				-- Not in list because it must have been deleted, don't silently pretend nothing was selected!
				-- index not safe to read if not valid? despite the fact that it is unique and likely still there?
				gui_names[idx] = string.format("[color=#a0a0a0][font=default-small] ?    [/font][/color] [color=#b0b0b0](Deleted platform)[/color]")
			end
		end
	end
	
	gui.refs.sel_list.items = gui_names
	gui.refs.sel_list.selected_index = sel_idx
	gui.sel_items = gui_items
end

-- handle ui element visbility and greyed-out state (gui -> gui)
---@param gui OpenGui
local function gui_update_vis_en(gui)
	local refs = gui.refs
	
	local mode = update_radiobutton(refs, MODES)
	
	local dyn = refs.dyn_enable.state
	refs.dynR.enabled = dyn
	refs.dynG.enabled = dyn
	refs.sel_orbit_only.visible = dyn and mode == "platforms"
	refs.dyn_text.visible = dyn
	refs.dyn_flow1.visible = dyn and mode == "platforms"
	refs.dyn_flow2.visible = dyn
	
	--refs.comms_pane.visible = mode == "comms"
	refs.pl_config.visible = mode == "platforms"
	
	if mode == "comms" then
	else
		local raw = refs.pl_mode.switch_state == "right"
		refs.pl_std.visible = not raw
		refs.pl_raw.visible = raw
	end
end

-- init ui from data or defaults (data -> gui)
-- this needs to update all invisible ui elements too!
---@param gui OpenGui
---@param data RadarData
local function radar2gui(gui, data)
	assert(data.entity and data.entity.valid)
	
	local refs = gui.refs
	local S = data.S
	
	refs.mode_comms.state = (S.mode or "comms") == "comms"
	refs.mode_platforms.state = S.mode == "platforms"
	
	refs.dyn_enable.state = S.dyn ~= nil
	local dyn = S.dyn or radars.radar_defaults.dyn
	refs.dynR.state = dyn.R
	refs.dynG.state = dyn.G
	refs.dyn_text.text = S.dyn_text or ""
	
	-- comms mode
	
	-- platforms mode
	if S.sel_orbit_only ~= nil then
		refs.sel_orbit_only.switch_state = S.sel_orbit_only and "right" or "left"
	else
		refs.sel_orbit_only.switch_state = radars.radar_defaults.sel_orbit_only and "right" or "left"
	end
	
	local read_mode = S.read_mode or "std"
	refs.pl_mode.switch_state = read_mode == "raw" and "right" or "left"
	
	for k,v in pairs(read_mode=="std" and S.read or radars.radar_defaults.std) do
		refs["pl_std"..k.."R"].state = v.R
		refs["pl_std"..k.."G"].state = v.G
	end
	for k,v in pairs(read_mode=="raw" and S.read or radars.radar_defaults.raw) do
		refs["pl_raw"..k.."R"].state = v.R
		refs["pl_raw"..k.."G"].state = v.G
	end
	
	--radar_gui_update_channels(gui, data)
	gui_update_platform_list(gui, data)
	
	gui_update_vis_en(gui)
end

-- global function because of circular dep
function refresh_all_guis()
	for _, gui in pairs(storage.open_guis) do
		--if gui.planet and gui.planet.prototype == planet and gui.data.S..state then
		radar2gui(gui, gui.data)
	end
end
---@param data RadarData
function refresh_gui(data)
	local gui = storage.open_guis2[data]
	if gui then
		gui_update_platform_list(gui, data)
	end
end

-- update data from ui (gui -> data + changes gui too)
---@param event any
local function gui_state_changed(event)
	local gui = storage.open_guis[event.player_index]
	if not gui then return end
	game.print("gui_state_changed: ".. serpent.block(event))
	local refs = gui.refs
	local data = gui.data
	assert(data.entity and data.entity.valid)
	
	-- rebuild settings here to minimize it to what is actually needed depending on mode
	-- full state of hidden panes is still kept in ui elements until gui is closed
	-- minizing should probably be in refresh_radar, but it's convenient here and avoids some data/ui desyncs
	local S = {}
	S.selected_platform = data.S.selected_platform -- take previous selection instead of pulling from ui list just before we update it
	
	data.S = S
	
	S.mode = update_radiobutton(refs, MODES, event.element.name)
	
	S.dyn = refs.dyn_enable.state and { R=refs.dynR.state, G=refs.dynG.state } or nil
	
	if S.mode == "comms" then
		--S.selected_channel = gui.drop_down_channels[gui.refs.ch_drop_down.selected_index]
		--
		--local ch = storage.channels.map[S.selected_channel]
		--if ch then
		--	ch.is_interplanetary = refs.ch_interplanetary.state
		--	radar_channels.update_is_interplanetary(ch.id)
		--end
		
		--data.S.selected_channel = gui.drop_down_channels[event.element.selected_index]
		--
		--if data.S.selected_channel == -1 then
		--	data.S.selected_channel = radar_channels.create_new_channel().id
		--end
		--
		--radar_gui_update_channels(gui, data)
	else
		if refs.dyn_enable.state then
			S.sel_orbit_only = refs.sel_orbit_only.switch_state == "right"
		else
			S.sel_orbit_only = nil
		end
		
		local raw = refs.pl_mode.switch_state == "right"
		--local read_mode = update_radiobutton(refs, READ_MODES, event.element.name)
		
		S.read_mode = raw and "raw" or "std"
		local ui_prefix = "pl_"..S.read_mode
		local read = {}
		for k,_ in pairs(radars.radar_defaults[S.read_mode]) do ---@diagnostic disable-line
			read[k] = { R=refs[ui_prefix..k.."R"].state,
			            G=refs[ui_prefix..k.."G"].state }
		end
		S.read = read
		
		-- mode or sel_orbit_only could have changed
		gui_update_platform_list(gui, data) -- do last, so settings are fully rebuilt
	end
	
	gui_update_vis_en(gui)
	
	radars.refresh_radar(data)
end
script.on_event({
	defines.events.on_gui_checked_state_changed,
	defines.events.on_gui_switch_state_changed,
}, gui_state_changed)

script.on_event(defines.events.on_gui_selection_state_changed, function(event)
	local gui = storage.open_guis[event.player_index]
	if not gui then return end
	--game.print("on_gui_selection_state_changed: ".. serpent.block(event))
	local data = gui.data
	assert(data.entity and data.entity.valid)
	
	if data.S.mode == "comms" then
		
	else
		data.S.selected_platform = gui.sel_items[event.element.selected_index]
		gui_update_platform_list(gui, data) -- update list so that fake entries disappear
	end
	
	radars.refresh_radar(data, true)
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
	local gui = storage.open_guis[event.player_index]
	if not gui then return end
	--game.print("on_gui_text_changed: ".. serpent.block(event))
	local data = gui.data
	assert(data.entity and data.entity.valid)
	
	if event.element.name == "dyn_text" then
		local text = event.element.text
		local trimmed = text:match "^%s*(.-)%s*$"
		data.S.dyn_text = string.len(trimmed) > 0 and trimmed or nil
		
		if data.S.mode == "comms" then
			
		else
			gui_update_platform_list(gui, data) -- do last, so settings are fully rebuilt
		end
	end
	
	radars.refresh_radar(data, true)
end)

script.on_event(defines.events.on_gui_click, function(event)
	local gui = storage.open_guis[event.player_index]
	if not gui then return end
	--game.print("on_gui_click: ".. serpent.block(event))
	local refs = gui.refs
	local data = gui.data
	assert(data.entity and data.entity.valid)
	
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
-- TODO: does text box .text actually change on confirmed,
-- or will we see mid-typing string if the gui updates outside of gui events like a radar switching channel?
script.on_event(defines.events.on_gui_confirmed, function(event)
	local gui = storage.open_guis[event.player_index]
	if not gui then return end
	local refs = gui.refs
	local data = gui.data
	assert(data.entity and data.entity.valid)
	
	--game.print("on_gui_confirmed: ".. serpent.block(event))
	if event.element.name == "dyn_text" then
		data.S.dyn_text = refs.dyn_text.text
		radars.refresh_radar(data, true)
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
		GUI{type="frame", direction="horizontal", style={base="subheader_frame", horizontally_stretchable=true}}:add{
			GUI{type="label", caption="Selection", style={base="subheader_caption_label", bottom_margin=5}},
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
	
	local dyn_text1 = "[virtual-signal=signal-P][font=default-small] select via platform ID[/font]"
	local dyn_text2 = "[virtual-signal=signal-number-sign][font=default-small] select via list index[/font]"
	local dyn_text4 = "[font=default-small]filter list by text[/font]"
	
	local id_sel_tt = "A positive [virtual-signal=signal-P] signal will select platforms directly by ID\nCan select unlisted platforms\nInvalid IDs will select [None]"
	local idx_sel_tt = "A positive [virtual-signal=signal-number-sign] signal will select from the list by index\nInvalid indices will select [None]"
	
	local all_platforms_tt = "List all platforms in ID order"
	local orbiting_tt = "List only platforms in orbit of planet\nRadars on platforms can also read platforms in their current orbit\nListed in order of arrival at planet"
	
	local dyn_enable_tt="Auto-select via circuit signal\nThe selection is only kept as long as the signal is held\nSelection is not processed every tick\nPlatform ID [virtual-signal=signal-P] selection has priority over list index [virtual-signal=signal-number-sign]\nHint: Platform IDs [virtual-signal=signal-P] returned by the status read option can be fed back through a combinator to lock a selection to a platform after it was picked by index"
	local dyn_text_tt="Filter the list via text\nThe text can be contained anywhere in the name\n'*' acts a general wildcard\nLetter codes like '{X}' act as a number from the corresponding signal [virtual-signal=signal-X]"

	
	local dyn_pane = gui_vflow{name="dyn_pane"}:add{
		gui_hflow{stlye={bottom_margin=5}}:add{
			GUI{type="checkbox", name="dyn_enable", caption="Dynamic Select", state=false,
			    style={base="caption_checkbox"}, tooltip=dyn_enable_tt},
			GUI{type="empty-widget", style={horizontally_stretchable=true}},
			GUI{type="checkbox", name="dynR", caption={"gui-network-selector.red-label"}, state=false},
			GUI{type="checkbox", name="dynG", caption={"gui-network-selector.green-label"}, state=false},
		},
		
		gui_hflow{name="dyn_flow1"}:add{
			GUI{type="label", caption=dyn_text1, tooltip=id_sel_tt},
			--GUI{type="empty-widget", style={horizontally_stretchable=true}},
			--GUI{type="label", caption=dyn_text2, tooltip=idx_sel_tt},
		},
		gui_hflow{name="dyn_flow2"}:add{
			GUI{type="label", caption=dyn_text2, tooltip=idx_sel_tt},
			GUI{type="empty-widget", style={horizontally_stretchable=true}},
			--GUI{type="checkbox", name="dyn_default_first", caption="Default First", state=false},
			--GUI{type="empty-widget", style={horizontally_stretchable=true}},
			GUI{type="switch", name="sel_orbit_only", switch_state="left", allow_none_state=false,
					left_label_caption="All", left_label_tooltip=all_platforms_tt,
					right_label_caption="Orbiting", right_label_tooltip=orbiting_tt},
		},
		
		--GUI{type="empty-widget", style={horizontally_stretchable=true}},
		--GUI{type="label", caption=dyn_text4},
		GUI{type="textfield", name="dyn_text", text="", tooltip=dyn_text_tt, style="stretchable_textfield"},
	}
	
	local pl_config = gui_vflow{name="pl_config"}:add{
		gui_hflow{}:add{
			GUI{type="label", caption="Platform signals", style={base="caption_label"}},
			GUI{type="empty-widget", style={horizontally_stretchable=true}},
			GUI{type="switch", name="pl_mode", switch_state="left", allow_none_state=false,
				left_label_caption="Standard", left_label_tooltip="Standard read mode",
				right_label_caption="Raw", right_label_tooltip="Raw read mode (Interplanetary reads possible)"},
		},
		gui_vflow{name="pl_std"}:add{
			circuit_enable("pl_stdSta", "Read status",               status_desc,tick2),
			circuit_enable("pl_stdReq", "Read unfulfilled requests", unful_req_desc,tick2),
		},
		gui_vflow{name="pl_raw"}:add{
			circuit_enable("pl_rawSta", "Read status",               status_desc,tick2),
			circuit_enable("pl_rawReq", "Read requests",             req_desc,tick2),
			circuit_enable("pl_rawOtw", "Read on the way",           otw_desc,tick2),
			circuit_enable("pl_rawInv", "Read inventory",            inv_desc,tick2),
			circuit_enable("pl_rawInvSlots", "Read inventory slots", inv_slots_desc,tick2),
		}
	}
	
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
	assert(entity and entity.valid)
	
	M.force_close_gui(player_index)
	
	local window, refs = window_def:add_to(player.gui.screen)
	window.force_auto_center()
	
	local data = radars.init_radar(entity)
	local gui = { refs=refs, data=data }
	storage.open_guis[player_index] = gui
	storage.open_guis2[data] = gui
	
	radar2gui(gui, data)
	
	-- a refresh every time the gui is opened is a good idea
	radars.refresh_radar(data)
	
	return window
end

---@param player_index player_index
function M.force_close_gui(player_index)
	local player = game.get_player(player_index)
	if player then
		local existing = player.gui.screen["hexcoder_radar_uplink"]
		if existing then
			local gui = storage.open_guis[player_index]
			storage.open_guis2[gui.data] = nil
			
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