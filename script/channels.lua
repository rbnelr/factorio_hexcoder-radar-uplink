--[[
TODO: rework!
-> Use alphbethic sorting, seems wrong with rich text as possibility, but game also gets the order 'wrong' with richt text in train station names

-> using signals as channels seems like an iteresting idea, especially with signal buttons in gui
 -> but probably clashes with my existing gui, and can probably be emulated with name wildcards
 
channel create can be button, fake option in list, or just typing into name field
channel delete can be button, or simply when no radar references it any more
-> dynamic selection can do more cool stuff if wildcard-selection can actually create channels by itself
-> allow {"anything"} signal to insert rich text into name, allow {X} to insert number
-> this could be very cool for LTN-style stuff but via circuits
-> literally if your train stops have unique names (which you sadly have to set manually)
   and the radar knows the name to use as a channel name, train stations can request items via the radar channel
   a central provider can iterate channels with requests, request those items via req chests, load them into trains, until they are full
   then send the destination stop via circuit and launch it via interrupt, might require a memory cell of train contents while on the way to avoid sending duplicates
   -> train interrupts can already do some (maybe all) of this, but it's cool!
 -> Once I have implemented this, demonstrate this via wall repair supply!

unsure how channels should work
 -> want to only show channels that can actually be connected to based on restriction
    want to add power draw when connecting across space, and want relay sats
    but relay sats would feel weird if they always need 2 radars (1 to connect to ground/or previous relay, 1 to connect to other relay)
     -> make hub itself do it? maybe that's less cool?
    actually -> connect radars to surface hub, then connect hubs according to rules
     but this means there's now not a single link radar that can get the power draw, we could add a "relay" checkbox, and you just need 1?

]]

---@class Channels
---@field surfaces table<surface_index, SurfaceChannels>
local Channels = {}
Channels.__index = Channels

---@class Channel
---@field name string
---@field special? integer
---@field is_interpl boolean?
---@field hub LuaEntity
---@field link_hub LuaEntity

---@class SurfaceChannels
---@field channels table<string, Channel>
---@field selection_list? Channel[]
---@field dbg_counter? integer

local W = defines.wire_connector_id
local W_circR = W.circuit_red
local W_circG = W.circuit_green
local HIDDEN = DEV and defines.wire_origin.player or defines.wire_origin.script
local STATUS_WORKING = defines.entity_status.working

local GLOBAL_CH_NAME = "[Global]" -- TODO: rename [default] or [surface-wide] ?

---@return Channels
function Channels.new()
	return setmetatable({ surfaces={} }, Channels)
end

local function _comp(l, r)
	local ordL = l.special
	local ordR = r.special
	if ordL == ordR then
		return l.name < r.name
	end
	return (ordL or 0) < (ordR or 0)
end

---@param data Radar
---@return Channel[]
function Channels:get_list_for_selection(data)
	local surf = self:init_surface(data.entity.surface)
	local list = surf.selection_list
	if list then
		return list
	end
	
	list = {}
	local i = 1
	for _,v in pairs(surf.channels) do
		list[i] = v
		i = i + 1
	end
	
	table.sort(list, _comp)
	
	surf.selection_list = list
	return list
end

---@param channel Channel
function Channels:refresh_surface_links(channel)
	--game.print("refresh_surface_links: ".. channel_name)
	
	channel.is_interpl = channel.is_interpl and ALLOW_INTERPL or nil
	local name = channel.name
	
	local prevR = nil
	local prevG = nil
	for _, surf in pairs(self.surfaces) do
		local channel = surf.channels[name]
		if channel then
			local l = channel.link_hub.get_wire_connectors(false)
			local lR = l[W_circR]
			local lG = l[W_circG]
			
			lR.disconnect_all(HIDDEN)
			lG.disconnect_all(HIDDEN)
			
			if channel.is_interpl then
				local h = channel.hub.get_wire_connectors(false)
				lR.connect_to(h[W_circR], false, HIDDEN)
				lG.connect_to(h[W_circG], false, HIDDEN)
			end
			
			if prevR then ---@cast prevG -nil
				lR.connect_to(prevR, false, HIDDEN)
				lG.connect_to(prevG, false, HIDDEN)
			end
			prevR = lR
			prevG = lG
		end
	end
end
function Channels:refresh_all_surface_links()
	
	local interpl_names = {}
	for _, surf in pairs(self.surfaces) do
		for name, channel in pairs(surf.channels) do
			interpl_names[name] = interpl_names[name] or channel.is_interpl
		end
	end
	
	for name,_ in pairs(interpl_names) do
		self:refresh_surface_links(name)
	end
end

---@param channel Channel
---@param is_interpl boolean
function Channels:set_is_interpl(channel, is_interpl)
	channel.is_interpl = is_interpl or nil
	
	self:refresh_surface_links(channel)
end

---@param surface LuaSurface
---@return SurfaceChannels
function Channels:init_surface(surface)
	local surf = self.surfaces[surface.index]
	if not surf then
		script.register_on_object_destroyed(surface)
		
		surf = { channels={} }
		self.surfaces[surface.index] = surf
		
		self:init_channel(surface, GLOBAL_CH_NAME)
	end
	return surf
end

---@param sid surface_index
function Channels:deleted_surface(sid)
	self.surfaces[sid] = nil
	
	self:refresh_all_surface_links()
end

---@param channel Channel?
---@return boolean
function Channels:can_edit(channel)
	return channel and channel.name ~= GLOBAL_CH_NAME or false
end

---@param surface LuaSurface
---@return Channel
function Channels:get_global(surface)
	local surf = self:init_surface(surface)
	return surf.channels[GLOBAL_CH_NAME]
end

--[[
---@param channel Channel
---@return integer
function Channels:get_num_connected_radars(channel)
	
	-- TODO: do ghost connections even happen? does undo delete radar create a ghost connection? Does it only if HIDDEN=player?
	local conn = channel.hub.get_wire_connectors(false)
	local connR = conn[W_circR]
	local connG = conn[W_circG]
	
	-- early out (?)
	if connR.connection_count == 0 and
	   connG.connection_count == 0 then
		return 0
	end
	
	-- really expensive due to radars being able to connect R,G or R+G
	local dedup_radars = {}
	for _, c in ipairs(connR.connections) do
		local entity = c.target.owner
		if entity.type == "radar" then
			dedup_radars[entity.unit_number] = true
		end
	end
	for _, c in ipairs(connG.connections) do
		local entity = c.target.owner
		if entity.type == "radar" then
			dedup_radars[entity.unit_number] = true
		end
	end
	
	return table_size(dedup_radars)
end
]]

---@param radar Radar
function Channels:refresh_channel_connection(radar)
	--game.print(">> channel_switch: ".. serpent.line({ entity, channel_name, surface }))
	
	local conn = radar.entity.get_wire_connectors(true)
	local connR = conn[W_circR]
	local connG = conn[W_circG]
	
	-- Store previous channel?
	
	--local old_channel = radar.S.selected
	--local old_hub = old_channel and old_channel.hub
	--if old_hub then
	--	local hconn = old_hub.get_wire_connectors(false)
	--	connR.disconnect_from(hconn[W_circR], HIDDEN)
	--	connG.disconnect_from(hconn[W_circG], HIDDEN)
	--end
	
	for _, c in ipairs(connR.connections) do
		if c.origin == HIDDEN and (c.target.owner.name == "hexcoder_radar_uplink-cc") then
			connR.disconnect_from(c.target, HIDDEN)
		end
	end
	for _, c in ipairs(connG.connections) do
		if c.origin == HIDDEN and (c.target.owner.name == "hexcoder_radar_uplink-cc") then
			connG.disconnect_from(c.target, HIDDEN)
		end
	end
	
	local new_channel = radar.S.selected
	if new_channel and new_channel.hub and radar.status == STATUS_WORKING then
		local cc = new_channel.hub.get_wire_connectors(false)
		connR.connect_to(cc[W.circuit_red  ], false, HIDDEN)
		connG.connect_to(cc[W.circuit_green], false, HIDDEN)
	end
end

---@param surface LuaSurface
---@param channel Channel
---@param new_name string
---@return boolean
function Channels:can_rename_channel(surface, channel, new_name)
	local surf = self:init_surface(surface)
	return string.len(new_name) > 0
		and channel.special == nil
		and surf.channels[new_name] == nil -- can't rename to existing name including of channel itself
end

---@param surface LuaSurface
---@param channel Channel
---@param new_name string
function Channels:rename_channel(surface, channel, new_name)
	local surf = self:init_surface(surface)
	assert(self:can_rename_channel(surface, channel, new_name) and surf.channels[channel.name] ~= nil)
	
	if string.len(new_name) > 0 and not surf.channels[new_name] then
		surf.channels[channel.name] = nil
		surf.channels[new_name] = channel
		surf.selection_list = nil -- invalidate
		
		channel.name = new_name
		
		-- this breaks things, retained-mode guis suck, who would've thunk that duplicating state is bad, huh?
		--refresh_all_guis()
	end
end

-- try "New channel", "New channel (2)", "New channel (3)" until unique name found
---@param surf SurfaceChannels
---@param base_name string
---@return string
local function generate_unique_name(surf, base_name)
	local names = surf.channels
	
	local name = base_name
	local i = 1
	while true do
		if not names[name] then
			return name
		end
		
		i = i + 1
		name = string.format("%s (%d)", base_name, i)
	end
end

-- return existing channel, laziliy create it with given name or with generated unique name
---@param surface LuaSurface
---@param name? string
---@param is_interpl? boolean
---@return Channel
function Channels:init_channel(surface, name, is_interpl)
	local surf = self:init_surface(surface)
	
	local channel = surf.channels[name]
	if channel then
		return channel
	end
	
	if name == nil or string.len(name) <= 0 then
		name = generate_unique_name(surf, "New channel")
	end
	
	-- TODO: update and move comments
	-- Hub to directly connect all radars that have this channel selected to
	-- Switching radar channel is now O(1)!
	-- If mod deinstalled, this hub disappears and automatically removes all hidden radar wires (and vanilla links reappear)!
	
	-- Interplanetary link hub, which connect connect in chain to same hub on all other surfaces
	-- Switching a channel interplanetary status is now O(1)!
	-- update_channel_surface_links() now only needs to be called on surface create/destroy!
	-- (If single hub existed, update_channel_surface_links() would need to be called on interplanetary toggle, and may have to iterate countless radar wires to find ones to remove)
	
	-- TODO: I guess unlike hidden entities under radars, or under platform hub,
	-- this technically is not that cool, since a mod might have surfaces that get generated a distance away from 0,0?
	-- This might thus cause chunks to load
	local base_x = 0.5
	local base_y = 0.5
	if DEV then
		-- could use a freelist to avoid leaving holes
		-- if dynamic channel creation is needed that would be a good approach to avoid recreating entities over and over
		local i = surf.dbg_counter or 0
		surf.dbg_counter = i + 1
		base_x = base_x + i
	end
	
	local hub = surface.create_entity{
		name="hexcoder_radar_uplink-cc", force="player",
		position={base_x, base_y}, snap_to_grid=false
	} ---@cast hub -nil
	hub.destructible = false
	hub.combinator_description = "Radar signal radar hub"
	
	local link_hub = surface.create_entity{
		name="hexcoder_radar_uplink-cc", force="player",
		position={base_x, base_y+1}, snap_to_grid=false
	} ---@cast link_hub -nil
	link_hub.destructible = false
	link_hub.combinator_description = "Radar signal surface hub"
	
	-- force create upfront (?)
	local _ = hub.get_wire_connectors(true)
	      _ = link_hub.get_wire_connectors(true)
	
	--update_channel_surface_links(id)
	
	local special
	if name == GLOBAL_CH_NAME then special = -1 end -- [Global] sorts as first item
	
	channel = { ---@type Channel
		name=name,
		is_interpl=is_interpl,
		special=special,
		hub=hub,
		link_hub=link_hub,
	}
	surf.channels[name] = channel
	surf.selection_list = nil -- invalidate
	
	self:refresh_surface_links(channel)
	
	refresh_all_guis()
	
	return channel
end

---@param surface LuaSurface
---@param channel Channel
function Channels:delete_channel(surface, channel)
	local surf = self:init_surface(surface)
	assert(channel.name ~= GLOBAL_CH_NAME and surf.channels[channel.name] ~= nil)
	
	-- deselect channels in connected radars (don't actually cut wires)
	local conn = channel.hub.get_wire_connectors(true)
	local connR = conn[W_circR]
	local connG = conn[W_circG]
	for _, c in ipairs(connR.connections) do
		if c.origin == HIDDEN and (c.target.owner.type == "radar") then
			radar_deselect_channel(c.target.owner)
		end
	end
	for _, c in ipairs(connG.connections) do
		if c.origin == HIDDEN and (c.target.owner.name == "radar") then
			radar_deselect_channel(c.target.owner)
		end
	end
	
	surf.channels[channel.name] = nil
	surf.selection_list = nil -- invalidate
	
	channel.hub.destroy()
	channel.link_hub.destroy()
	
	refresh_all_guis()
end

return Channels