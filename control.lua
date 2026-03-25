--[[
Ideas:
  Connected circuit network 
  * Radar      | Circuit connection
  * Platforms  | connected mode + config
  
  -Named channels for comms, allow interplanetary via option (increase power draw?)
  -Text-field with wildcards filled in dynamically by circuits for dynamic platform/channel selection
  -Count enemies/any entity in radar range (experimental, via setting), test how to do this with good performance. Maybe scan 1 chunk per tick, buffer results per chunk to increment decrement total while scanning? -> set filtered entities via circuit signals, are entity prototypes?
  
--]]

-- TODO: refactor code: model being
-- get_entity_data(entity/id) -> get or insert entity data with default settings
-- can then modify settings etc
-- data.refresh() -> refresh after settings were modified, this can delete itself from storage if settings are default, de/spawn combinators, or rewire
-- data.destroy() or reset() -> reset settings and thus despawn and revert all mod combinators (can be implemented by resetting settings and then calling refresh?)

-- TODO: removing glib dependency would be easy
local util = require("util")
local glib = require("__glib__/glib")
local default_frame = require("__glib__/examples/default_frame")
--local prnt = {sound=defines.print_sound.never}

local function round(num)
	return num >= 0 and math.floor(num + 0.5) or math.ceil(num - 0.5)
end
local netR = {red=true, green=false}
local netG = {red=false, green=true}

local function init(event)
	storage.radars = {}
	storage.platforms = {} 
	storage.open_guis = {}
	storage.polling_radars = {}
	storage.polling_platforms = {}
end

local handlers = {}

local function _reset(event) -- allow me to fix outdated state during dev
	for _, player in pairs(game.players) do player.opened = nil end
	storage.open_guis = nil
	
	storage.radars = nil
	storage.platforms = nil
	
	for _, s in pairs(game.surfaces) do
		for _, cc in pairs(s.find_entities_filtered{ type="constant-combinator", name="hexcoder_radar_uplink_cc" }) do
			cc.destroy()
		end
		for _, cc in pairs(s.find_entities_filtered{ type="decider-combinator", name="hexcoder_radar_uplink_dc" }) do
			cc.destroy()
		end
	end
	
	init()
end
script.on_init(function(event)
	init()
end)

local function is_radar(entity)
	return entity and entity.valid and entity.type == "radar" and entity.name == "radar"
end
local function get_radar(entity)
	return storage.radars[entity.unit_number]
end

local function update_platform_status(data)
	local plat = data.platform
	local ctrl = data.ccs[1].get_control_behavior()
	
	local signals = {}
	-- platform index
	table.insert(signals, {value={type="virtual", name="signal-P", quality="normal"}, min=plat.index})
	
	-- signal space location that platform is orbiting
	if plat.space_location then
		table.insert(signals, {value={type="space-location", name=plat.space_location.name, quality="normal"}, min=1})
		
		storage.polling_platforms[data.platform.index] = nil
	-- signal space connection platform travelling
	-- since space connections are not supported as signals, output from/to space locations as signals with -1/-2 value
	-- dont do 1/2 like platform hub, due to conflict with space_location, avoid using 2/3 to allow nauvis>0 as condition (use nauvis<0 to check if platform is leaving or arriving)
	elseif plat.space_connection then
		local conn = plat.space_connection
		local from = conn.from
		local to   = conn.to
		local speed = plat.speed
		local progress = plat.distance
		--local reverse = speed and speed < 0.0 -- speed is never reported negative
		local sched = plat.schedule
		local sched_targ = sched and sched.records[sched.current].station
		
		local reverse = nil
		
		-- report travel direction based on prev and current progress
		if data._prev_conn == conn then
			reverse = progress < data._prev_progress
		end
		data._prev_conn = conn
		data._prev_progress = progress
		
		--game.print(" > delta: ".. delta .." speed: ".. _speed .."reported: ".. speed .." fac: ".. (_speed / speed), p)
		
		table.insert(signals, {value={type="space-location", name=sched_targ, quality="normal"}, min=-10})
		
		if speed then
			-- speed is per tick
			speed = round(speed * 60.0)
			table.insert(signals, {value={type="virtual", name="signal-V", quality="normal"}, min=speed})
		end
		
		-- Only report connection and progress/dist when direction can be safely determined (don't output for one update tick)
		if reverse ~= nil then
			if reverse then
				from = conn.to
				to   = conn.from
				progress = 1.0 - progress
			end
			
			table.insert(signals, {value={type="space-location", name=from.name, quality="normal"}, min=-1})
			table.insert(signals, {value={type="space-location", name=  to.name, quality="normal"}, min=-2})
			
			if progress then
				-- distance is in [0,1]
				local percent = round(progress * 100.0)
				local dist_km = round(progress * conn.length)
				table.insert(signals, {value={type="virtual", name="signal-T", quality="normal"}, min=percent})
				table.insert(signals, {value={type="virtual", name="signal-D", quality="normal"}, min=dist_km})
			end
		end
		
		-- in transit, update in real time
		storage.polling_platforms[data.platform.index] = true
	end
	
	ctrl.sections[1].filters = signals
end
--[[
-- iterate space platform hub logistic requests and compute remaining requests (items on the way are only counted once rocket is launched, i think)
-- returns as table["<quality>"]["<item_name>"] = request_count_excluding_on_the_way
local function compute_platform_requests(to_platform, from_planet)

	-- Platform hub inventory (excludes hub_trash)
	local inv = to_platform.hub.get_inventory(defines.inventory.hub_main)
	-- Platform hub logistic points
	-- for hubs we have 2: { requester, passive_provider }, iterate both to be safe
	local logi = to_platform.hub.get_logistic_point()
	local reqests = {}
	
	for _, lp in ipairs(logi) do
		
		for _, sec in ipairs(lp.sections) do
			--game.print(" > sec: ".. serpent.block(sec.active))
			if sec.active then
				for _, fil in ipairs(sec.filters) do
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
		for _, item in ipairs(lp.targeted_items_deliver) do
			local q = reqests[item.quality]
			local i = q and q[item.name]
			if i then
				q[item.name] = i - item.count
			end
		end
	end
	return reqests
end

local effective_requests = compute_platform_requests(platf, radar_planet)
for quality, items in pairs(effective_requests) do
	for item, count in pairs(items) do
		if count > 0 then
			table.insert(signals, { value={ type="item", name=item, quality=quality }, min=count })
		end
	end
end
]]
local function update_platform_requests_at_planet(data)
	local plat = data.platform
	--if not plat.space_location then return end
	
	local ctrl = data.ccs[2].get_control_behavior()
	
	local signals = {}
	table.insert(signals, { value={ type="virtual", name="signal-info", quality="normal" }, min=1 })
	
	-- Platform main hub inventory (trash slots are hub_trash)
	local inv = plat.hub.get_inventory(defines.inventory.hub_main)
	-- Platform hub logistic points, for hubs we have 2: { requester, passive_provider }
	local logi = plat.hub.get_logistic_point()[1] -- access directly to avoid iteration
	
	if logi.filters then
		game.print(">> filters: ")
		
		-- this already filters by "import from" planet
		for _, fil in ipairs(logi.filters) do
			game.print(" > ".. serpent.line(fil))
			-- we can ignore comparator since only =quality setting can have min (others only apply max count which does not result in requests, but the platform dropping items) 
			if fil.count > 0 then -- type==nil, probably because hub requests have to be items
				table.insert(signals, {
					value = { type="item", name=fil.name, quality=fil.quality },
					min = fil.count
				})
			end
		end
	end
	
	ctrl.sections[1].filters = signals
end
local function _update_platform_requests(platform)
	signals[3] = { value={ type="virtual", name="signal-info", quality="normal" }, min=1 }
	local slot = 4
	
	-- Platform main hub inventory (trash slots are hub_trash)
	local inv = platform.hub.get_inventory(defines.inventory.hub_main)
	-- Platform hub logistic points, for hubs we have 2: { requester, passive_provider }
	local logi = platform.hub.get_logistic_point()[1] -- access directly to avoid iteration
	
	p = {skip=defines.print_skip.never}
	
	-- targeted_items_deliver and logistic point filters are already summed up per item/quality!
	-- can simply output signal instead of manally summing up
	
	-- items already on the way
	--game.print(" > targeted_items_deliver: ".. serpent.block(logi.targeted_items_deliver), p)
	--local on_the_way = {}
	--for _, item in ipairs(logi.targeted_items_deliver) do
	--	local q = on_the_way[item.quality]
	--	local i = q and q[item.name]
	--	if i then
	--		q[item.name] = item.count
	--	end
	--end
	--
	--local contents = {}
	--for _, item in ipairs(inv.get_contents()) do
	--	local q = contents[item.quality]
	--	local i = q and q[item.name]
	--	if i then
	--		q[item.name] = item.count
	--	end
	--end
	
	if logi.filters then
		--game.print(">> filters:")
		-- this already filters by "import from" planet
		for _, fil in ipairs(logi.filters) do
			--game.print(" > ".. serpent.line(fil))
			-- we can ignore comparator since only =quality setting can have min (others only apply max count which does not result in requests, but the platform dropping items) 
			if fil.count > 0 then -- type==nil, probably because hub requests have to be items
				--game.print(" > ".. fil.name .." ".. fil.quality .." ".. fil.count, p)
				
				local count = fil.count
				
				--local otwq = on_the_way[fil.quality]
				--local otw = otwq and otwq[fil.name]
				--if otw then count = count - otw end
				--
				--local contq = contents[fil.quality]
				--local cont = contq and contq[fil.name]
				--if cont then count = count - cont end
				
				--count = count - inv.get_item_count({name=fil.name, quality=fil.quality})
				
				if count > 0 then
					signals[slot] = {
						value = { type="item", name=fil.name, quality=fil.quality },
						min = count
					}
					slot = slot + 1
				end
			end
		end
	end
end

-- to allow this mod to read platform data onto the circuit network wires, we want to stop the vanilla behavior of radars sharing circuit signals automatically
-- to do so we need to remove the hidden wire_origin.radar wire, which cannot be done from lua
-- It would be possible to make a copy of the radar prototype with connects_to_other_radars=false, and switch out the radars on demand
-- but alternatively I can implement it in lua via wire_origin.script
-- this costs performance on user interaction and may be brittle, but has the upside that I can later add the planned feature to send data in names channels
-- This O(N) or O(N^2) algo could be optimized into O(1) linked list add/remove operation!
local function update_global_radar_channel_wires(surface)
	local radars = surface.find_entities_filtered{ type="radar", name="radar" }
	
	-- connect all radars of same channel in chain
	for _, w in ipairs({ defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green }) do
		local prev = nil
		for _, radar in ipairs(radars) do
			local data = get_radar(radar)
			local channel = data and data.S.mode -- nil == global channel
			
			local con = radar.get_wire_connectors(true)[w] -- true: create connector: if no current connections, would otherwise return nil
			-- disconnect all previous script connections, assuming that these are the ones we made in this function
			-- this may break other mods! TODO: only disconnect radar-to-radar connections?
			--con.disconnect_all(defines.wire_origin.script)
			
			for _, c in ipairs(con.connections) do
				if c.origin == defines.wire_origin.script and c.target.owner.type == "radar" and c.target.owner.name == "radar" then
					con.disconnect_from(c.target, defines.wire_origin.script)
				end
			end
			
			if channel == nil then
				if prev then
					con.connect_to(prev, false, defines.wire_origin.script)
				end
				prev = con
			end
		end
	end
end
local function debug_vis_wires(surface, time_to_live)
	local function _vis(entities)
		for _, w in ipairs({
			{t=defines.wire_connector_id.circuit_red  , col = { 1, .2, .2 }, offset={x=0, y=0}},
			{t=defines.wire_connector_id.circuit_green, col = { .2, 1, .2 }, offset={x=-.1, y=-.1}},
		}) do
			for _, e in ipairs(entities) do
				local con = e.get_wire_connectors()
				con = con[w.t] and con[w.t].connections or {}
				--game.print(">> con: ".. serpent.block(con))
				for _, c in ipairs(con) do
					if c.origin == defines.wire_origin.script then
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
	_vis(surface.find_entities_filtered{ name="hexcoder_radar_uplink_cc" })
	_vis(surface.find_entities_filtered{ name="hexcoder_radar_uplink_dc" })
end

-- there seems to be no event for scheduled_for_deletion, so lets just stay connected until it is deleted
local function platform_valid(p)
	-- platforms being built don't have a hub yet
	return p and p.valid and p.hub and p.hub.valid
end
local function get_platform_or_init(platform)
	if not platform_valid(platform) then return nil end
	
	local data = storage.platforms[platform.index]
	if not data then
		local reg_id, index = script.register_on_object_destroyed(platform)
		
		local ccs = {}
		for i=1,4 do
			ccs[i] = platform.surface.create_entity{
				name="hexcoder_radar_uplink_cc", force=platform.force,
				position={platform.hub.position.x+i-2, platform.hub.position.y+3}, snap_to_grid=false,
				direction=defines.direction.south
			}
			ccs[i].destructible = false
		end
		
		--ccs[1].get_control_behavior().sections[1].filters = {
		--	{value={type="virtual", name="signal-P", quality="normal"}, min=platform.index},
		--	{value={type="virtual", name="signal-A", quality="normal"}, min=1},
		--}
		--ccs[2].get_control_behavior().sections[1].filters = {
		--	{value={type="virtual", name="signal-P", quality="normal"}, min=platform.index},
		--	{value={type="virtual", name="signal-B", quality="normal"}, min=1},
		--}
		--ccs[3].get_control_behavior().sections[1].filters = {
		--	{value={type="virtual", name="signal-P", quality="normal"}, min=platform.index},
		--	{value={type="virtual", name="signal-C", quality="normal"}, min=1},
		--}
		
		data= {
			platform=platform,
			ccs=ccs,
		}
		storage.platforms[index] = data
		
		update_platform_status(data)
		update_platform_requests_at_planet(data)
	end
	return data
end
local function reset_platform(platform)
	local data = storage.platforms[platform.index]
	for _,v in ipairs(data.ccs) do
		v.destroy()
	end
	storage.platforms[platform.index] = nil
end

local function reset_radar(id)
	local data = storage.radars[id]
	if data then
		if data.dcs then
			for _,v in ipairs(data.dcs) do
				v.destroy()
			end
		end
		storage.radars[id] = nil
		storage.polling_radars[id] = nil
	end
end
local function refresh_radar(data)
	-- delete all data and spawned entities if dafault mode
	if data.S.mode == nil then
		reset_radar()
		return
	end
	
	local entity = data.entity
	
	local W = defines.wire_connector_id
	local hidden = defines.wire_origin.player -- defines.wire_origin.script
	
	local platform = data.entity.force.platforms[data.selected_platform]
	local plat_data = get_platform_or_init(platform)
	
	if not data.dcs then
		data.dcs = {}
		for i=1,2 do
			data.dcs[i] = entity.surface.create_entity{
				name="hexcoder_radar_uplink_dc", force=entity.force,
				position={entity.position.x+i-2, entity.position.y+0.5}, snap_to_grid=false,
				direction=defines.direction.south
			}
			data.dcs[i].destructible = false
		end
	end
	
	local planet_sig = {type="space-location", name=entity.surface.planet.prototype.name}
	local params = {
		{conditions={
			{first_signal={type="virtual", name="signal-each"}, constant=0, comparator=">=", compare_type="and", first_signal_networks=netR}
		},outputs={
			{signal={type="virtual", name="signal-each"}, copy_count_from_input=true, networks=netR}
		}},
		
		{conditions={
			{first_signal={type="virtual", name="signal-each"}, constant=0, comparator=">", first_signal_networks=netR},
			{first_signal=planet_sig, constant=0, comparator=">", first_signal_networks=netG},
		},outputs={
			{signal={type="virtual", name="signal-each"}, copy_count_from_input=true, networks=netR}
		}},
	}
	local R = entity.get_wire_connectors(true)
	local dcStat = data.dcs[1].get_wire_connectors(true)
	local dcReq = data.dcs[2].get_wire_connectors(true)
	
	local RG = { data.S.read_plat_statusRG, data.S.read_plat_requestsRG }
	for i=1,2 do
		local combinator = data.dcs[i]
		combinator.get_control_behavior().parameters = params[i]
		local con = combinator.get_wire_connectors(true)
		
		con[W.combinator_output_red  ].disconnect_all(hidden)
		con[W.combinator_output_green].disconnect_all(hidden)
		if RG[i] % 2 > 0 then con[W.combinator_output_red  ].connect_to(R[W.circuit_red  ], false, hidden)  end
		if RG[i] >= 2    then con[W.combinator_output_green].connect_to(R[W.circuit_green], false, hidden)  end
	end
	
	local dcStatR = dcStat[W.combinator_input_red]
	local connected = plat_data and dcStatR.connection_count == 1
		and dcStatR.connections[1].target.owner.surface == platform.surface
	if not connected then 
		dcStat[W.combinator_input_red  ].disconnect_all(hidden)
		dcStat[W.combinator_input_green].disconnect_all(hidden)
		dcReq[W.combinator_input_red  ].disconnect_all(hidden)
		dcReq[W.combinator_input_green].disconnect_all(hidden)
		
		if plat_data then
			game.print("reconnect!")
			
			local ccStat = plat_data.ccs[1].get_wire_connectors(true)
			local ccReq = plat_data.ccs[2].get_wire_connectors(true)
			--local c = plat_data.ccs[3].get_wire_connectors(true)
			
			-- platform status to platform status on red wire
			dcStatR.connect_to(ccStat[W.circuit_red], false, defines.wire_origin.script)
			
			-- platform raw requests to request on red wire
			-- platform status to requests on green wire for planet check
			dcReq[W.combinator_input_red  ].connect_to(ccReq [W.circuit_red  ], false, hidden)
			dcReq[W.combinator_input_green].connect_to(ccStat[W.circuit_green], false, hidden)
			
			connected = true
		end
	end
	
	storage.polling_radars[entity.unit_number] = (not connected) or nil -- poll if not connected yet due to to platform build pending
end
local function get_radar_or_init(entity, copy_settings)
	local data = get_radar(entity)
	if not data then
		local reg_id, unit_num = script.register_on_object_destroyed(entity)
		data = {
			entity = entity,
			S = util.table.deepcopy(copy_settings) or { -- settings
				mode = nil, -- nil: default circuit sharing mode, "platforms": circuits read platforms
				read_plat_status = true,
				read_plat_statusRG = 3,
				read_plat_requests = true,
				read_plat_requestsRG = 3,
				selected_platform = nil, -- LuaSpacePlatform.index
			}
		}
		storage.radars[unit_num] = data
	end
	refresh_radar(data)
	return data
end

--on_entity_logistic_slot_changed 

script.on_event(defines.events.on_space_platform_changed_state, function (event)
	game.print("on_space_platform_changed_state: platf ".. event.platform.index .." new_state: ".. serpent.line(event.platform.state))
	
	local data = storage.platforms[event.platform.index]
	if data then
		update_platform_status(data)
		
		if event.platform.state == defines.space_platform_state.waiting_at_station then
			update_platform_requests_at_planet(data)
		end
	end
end)
script.on_event(defines.events.on_entity_logistic_slot_changed, function (event)
	local entity = event.entity
	if entity.type == "space-platform-hub" then
		local platform = entity.surface and entity.surface.platform
		if platform then
			local data = storage.platforms[platform.index]
			if data then
				update_platform_requests_at_planet(data)
			end
		end
	end
end)

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
			
			local name = platf.name
			if not platform_valid(platf) then name = name.." (Not fully built)"
			elseif platf.scheduled_for_deletion ~= 0 then name =
				name.." [color=#f00000][virtual-signal=signal-trash-bin] (Scheduled for deletion)[/color]" end
			
			drop_down_strings[counter] = name
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
	local gui = storage.open_guis[event.player_index]
	local data = get_radar(gui.entity)
	
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
	
	if event.element.name == "mode1" or event.element.name == "mode2" then
		update_global_radar_channel_wires(gui.entity.surface)
	end
	
	refresh_radar(data)
end
function handlers.radar_drop_down(event)
	local gui = storage.open_guis[event.player_index]
	local data = get_radar(gui.entity)
	
	if event.element.name == "platform_drop_down" then
		data.selected_platform = gui.drop_down_platforms[event.element.selected_index]
	end
	
	radar_gui_update_platforms(gui, data)
	refresh_radar(data)
end
function handlers.entity_window_close_button(event)
	-- need to call this on default_frame close button or else it will leave player.opened with invalid values
	game.get_player(event.player_index).opened = nil
end

local function radar_gui_update(gui)
	local data = get_radar_or_init(entity)
	
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
	
	refresh_radar(data)
end

local function create_radar_gui(player, entity)
	-- TODO: cursor is not finger pointer on draggable titlebar like with built in guis?
	local window, refs = glib.add(player.gui.screen,
		default_frame("hexcoder_radar_uplink", "Radar circuit connection", { button=handlers.entity_window_close_button }))
	window.force_auto_center()
	
	local status_descr = "Read space platform status with unlimited range.\n"
	.."[virtual-signal=signal-P]: Platform ID\n"
	.."[space-location=nauvis]=1  Currently orbited planet - Check using [space-location=nauvis]>0\n"
	.."[space-location=nauvis]=-1 [space-location=gleba]=2  Travelling on space connection [space-location=nauvis]->[space-location=gleba] - Platform travel direction is respected\n"
	.."[space-location=aquilo]=-10  Actually targetted planet in next schedule stop\n"
	.."[virtual-signal=signal-T]  Space connection progress in % and [virtual-signal=signal-D] in km\n"
	
	local request_descr = "Read unfulfilled space platform requests.\n"
	.."Limited to platforms in orbit - signal indicated by [virtual-signal=signal-info]\n"
	
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
			{args={type = "frame", direction = "vertical", name="platforms_pane", style = "inside_shallow_frame_with_padding"}, children={
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
	
	local gui = { refs=refs, entity_id=entity.unit_number, entity=entity }
	storage.open_guis[player.index] = gui
	
	radar_gui_update(gui)
	
	return window
end



----
local _skip_closing_sound = nil
local function can_open_entity_gui(player, entity)
	return entity.valid and player.force == entity.force and player.can_reach_entity(entity)
end
-- reacting to LMB requires custom input(?)
-- TODO: enable configuring ghosts? If that is done, can I keep settings on building correctly? via tags? will gui stay open during build process?
script.on_event("hexcoder_radar_uplink_left-click", function(event)
	local player = game.get_player(event.player_index)
	local entity = player.selected -- hovered entity
	local free_cursor = not (player.cursor_stack.valid_for_read or player.cursor_ghost or player.cursor_record)
	
	if free_cursor then
		if is_radar(entity) and can_open_entity_gui(player, entity) then
			-- keep gui open if exact entity already open
			local open_gui = player.opened and storage.open_guis[player.index]
			if open_gui and entity.unit_number == open_gui.entity_id then return end
			
			-- close regular or custom gui first
			_skip_closing_sound = true
			player.opened = nil
			_skip_closing_sound = nil
			
			-- guis in player.opened will close via E and Escape automatically
			player.opened = create_radar_gui(player, entity)
			
			player.play_sound{ path="hexcoder_radar_uplink_open-sound" }
		end
	end
end)
script.on_event(defines.events.on_gui_closed, function(event)
	if event.element and event.element.name == "hexcoder_radar_uplink" then
		local player = game.get_player(event.player_index)
		
		if event.element.name == "hexcoder_radar_uplink" and not _skip_closing_sound then
			player.play_sound{ path="hexcoder_radar_uplink_close-sound" }
		end
		
		storage.open_guis[event.player_index] = nil
		event.element.destroy()
	end
end)
local function tick_gui(player, gui)
	-- close custom gui once out of reach
	if not can_open_entity_gui(player, gui.entity) then
		_skip_closing_sound = true
		player.opened = nil
		_skip_closing_sound = nil
	end
end

-- this now allows blueprint to copy custom settings, supports on_entity_cloned
-- blueprinting over does not
-- entities dying due to damage don't keep settings yet
-- things being built due to undo redo don't work yet
local function on_created_entity(event)
	local entity = event.entity or event.destination
	
	if event.source then
		get_radar_or_init(entity, storage.radars[event.source.unit_number].S)
	elseif event.tags then
		get_radar_or_init(entity, event.tags["hexcoder_radar_uplink"])
	end
	
	-- This needs to happen for all radars
	update_global_radar_channel_wires(entity.surface)
end
-- for all radars
local function on_entity_died(event)
	update_global_radar_channel_wires(event.entity.surface)
end
-- for all radars that had custom settings
script.on_event(defines.events.on_object_destroyed, function(event)
	if event.type == defines.target_type.entity then
		for player_i, gui in pairs(storage.open_guis) do
			-- close open entity gui if entity destroyed
			if event.useful_id == gui.entity_id then
				game.get_player(player_i).opened = nil
			end
		end
		
		reset_radar(event.useful_id)
	else
		storage.platforms[event.useful_id] = nil
	end
end)

for _, event in ipairs({
	defines.events.on_built_entity,
	defines.events.on_robot_built_entity,
	defines.events.on_space_platform_built_entity,
	defines.events.script_raised_built,
	defines.events.script_raised_revive,
	defines.events.on_entity_cloned,
}) do script.on_event(event, on_created_entity, {{filter = "type", type = "radar"}, {filter = "name", name = "radar"}}) end
script.on_event(defines.events.on_entity_died, on_entity_died, {{filter = "type", type = "radar"}, {filter = "name", name = "radar"}})

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
			local data = get_radar(entity)
			
			if is_radar(entity) and data then
				local tags = bp_entity.tags or {}
				tags["hexcoder_radar_uplink"] = data.S
				bp_entity.tags = tags
				-- need to modify name somehow if entity has custom name and and ghost version does not match somehow? (protocol_1903 [pY] on discord)
				
				changed = true
			end
		end
	end
	if changed then
		blueprint.set_blueprint_entities(entities)
	end
end)

-- on_(pre_)entity_settings_pasted doesn't get called for entities with no vanilla settings :(

script.on_nth_tick(6, function(event)
	for player_i, gui in pairs(storage.open_guis) do
		tick_gui(game.get_player(player_i), gui)
	end
	
	for id,_ in pairs(storage.polling_radars) do
		refresh_radar(storage.radars[id])
	end
	
	for id,_ in pairs(storage.polling_platforms) do
		update_platform_status(storage.platforms[id])
	end
	
	--tick_radars()
end)

commands.add_command("hexcoder_radar_uplink_vis", nil, function(command)
	-- debug: visualize connections
	for _, p in pairs(game.players) do
		debug_vis_wires(p.surface, 60*10)
	end
	
	game.print("storage.open_guis:")
	for k,v in pairs(storage.open_guis) do
		game.print(k ..": ".. serpent.line(v))
	end
	game.print("storage.platforms:")
	for k,v in pairs(storage.platforms) do
		game.print(k ..": ".. serpent.line(v))
	end
	game.print("storage.radars:")
	for k,v in pairs(storage.radars) do
		game.print(k ..": ".. serpent.line(v))
	end
end)
commands.add_command("hexcoder_radar_uplink_reset", nil, function(command)
	_reset()
end)

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
