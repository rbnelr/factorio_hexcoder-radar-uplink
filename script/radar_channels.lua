---@class Channels
---@field next_id channel_id
---@field map table<channel_id, Channel>
---@field surfaces table<surface_index, SurfaceChannels>

---@class Channel
---@field id channel_id
---@field name string
---@field is_interplanetary boolean

---@class SurfaceChannels
---@field channels table<channel_id, ChannelHubs>

---@class ChannelHubs
---@field hub LuaEntity
---@field link_hub LuaEntity


local M = {}

-- simply re-link all link hubs of this channel on all registered surfaces
-- could be optimized by using actual linked list logic, list of surfaces with radars will be small
---@param id channel_id
local function update_channel_surface_links(id)
	--game.print(">> update_channel_surface_links: ".. channel_name)
	
	local channel = storage.channels.map[id]
	if not channel then return end
	
	channel.is_interplanetary = channel.is_interplanetary and storage.settings.allow_interpl --[[@as boolean]]
	
	local prevR = nil
	local prevG = nil
	for _, surf in pairs(storage.channels.surfaces) do
		local hubs = surf.channels[id]
		if hubs then
			local h = hubs.hub.get_wire_connectors(true)
			local l = hubs.link_hub.get_wire_connectors(true)
			
			local lR = l[W.circuit_red  ]
			local lG = l[W.circuit_green]
			
			lR.disconnect_all(HIDDEN)
			lG.disconnect_all(HIDDEN)
			
			if channel.is_interplanetary then
				lR.connect_to(h[W.circuit_red  ], false, HIDDEN)
				lG.connect_to(h[W.circuit_green], false, HIDDEN)
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
function M.update_is_interplanetary(id)
	-- Abuse this to switch is_interplanetary, could be done more efficiently
	update_channel_surface_links(id)
end
function M.update_all_channels_is_interplanetary()
	for id,_ in pairs(storage.channels.map) do
		M.update_is_interplanetary(id)
	end
end

---@returns Channel
function M.create_new_channel()
	local chs = storage.channels
	local ch = { id=chs.next_id, name="New channel", is_interplanetary=false }
	chs.map[ch.id] = ch
	chs.next_id = chs.next_id + 1
	return ch
end

---@param surf SurfaceChannels
---@param id channel_id
local function destroy_hubs(surf, id)
	--game.print(">> destroy_channel: ".. serpent.block({ surfch, id }))
	local channel = surf.channels[id]
	if channel then
		channel.hub.destroy()
		channel.link_hub.destroy()
		
		surf.channels[id] = nil
		
		-- fix broken link
		update_channel_surface_links(id)
	end
end

---@param id channel_id
function M.destroy_channel(id)
	if id <= 1 then return end -- defensive: gui may mess up, can't destroy [None] or [Global]
	local chs = storage.channels
	
	for _, surf in pairs(chs.surfaces) do
		destroy_hubs(surf, id)
	end
	
	chs.map[id] = nil
end

-- init channel for surface, if the same channel get connected to from other surface, their link_hub will be connected
---@param surface LuaSurface
---@param id channel_id
---@returns ChannelHubs?
local function init_channel(surface, id)
	local channel = storage.channels.map[id]
	if not channel then return nil end -- blueprinting not correct for channels
	
	-- lazily create surface data
	local surf = storage.channels.surfaces[surface.index]
	if not surf then
		surf = { channels={} }
		storage.channels.surfaces[surface.index] = surf
	end
	
	-- lazily create channel data
	local hubs = surf.channels[id]
	if not hubs then
		-- Hub to directly connect all radars that have this channel selected to
		-- Switching radar channel is now O(1)!
		-- If mod deinstalled, this hub disappears and automatically removes all hidden radar wires (and vanilla links reappear)!
		local hub = surface.create_entity{
			name="hexcoder_radar_uplink-cc", force="player",
			position={id+0.5, 0.5}, snap_to_grid=false
		} ---@cast hub -nil
		hub.destructible = false
		hub.combinator_description = "Radar signal radar hub :".. surface.name ..":".. id
		
		-- Interplanetary link hub, which connect connect in chain to same hub on all other surfaces
		-- Switching a channel interplanetary status is now O(1)!
		-- update_channel_surface_links() now only needs to be called on surface create/destroy!
		-- (If single hub existed, update_channel_surface_links() would need to be called on interplanetary toggle, and may have to iterate countless radar wires to find ones to remove)
		local link_hub = surface.create_entity{
			name="hexcoder_radar_uplink-cc", force="player",
			position={id+0.5, 1.5}, snap_to_grid=false
		} ---@cast link_hub -nil
		link_hub.destructible = false
		link_hub.combinator_description = "Radar signal surface hub :".. surface.name ..":".. id
		
		hubs = { hub=hub, link_hub=link_hub }
		surf.channels[id] = hubs
		
		update_channel_surface_links(id)
	end
	
	return hubs
end

---@param entity LuaEntity
---@param id channel_id
---@param surface LuaSurface
local function channel_switch(entity, id, surface)
	--game.print(">> channel_switch: ".. serpent.line({ entity, channel_name, surface }))
	
	local conR = entity.get_wire_connectors(true)[W.circuit_red]
	local conG = entity.get_wire_connectors(true)[W.circuit_green]
	
	for _, c in ipairs(conR.connections) do
		if c.origin == HIDDEN and (c.target.owner.name == "hexcoder_radar_uplink-cc") then
			conR.disconnect_from(c.target, HIDDEN)
		end
	end
	for _, c in ipairs(conG.connections) do
		if c.origin == HIDDEN and (c.target.owner.name == "hexcoder_radar_uplink-cc") then
			conG.disconnect_from(c.target, HIDDEN)
		end
	end
	
	if id > 0 then -- 0 is [None] channel
		local hubs = init_channel(surface, id)
		if hubs then
			local cc = hubs.hub.get_wire_connectors(true)
			conR.connect_to(cc[W.circuit_red  ], false, HIDDEN)
			conG.connect_to(cc[W.circuit_green], false, HIDDEN)
		end
	end
end
---@param data RadarData
function M.update_radar_channel(data)
	--game.print(">> update_radar_channel: ".. serpent.block(data))
	
	local channel_id = 0 -- [None] channel
	if data.S.mode == "comms" and data.S.selected_channel and data.status == defines.entity_status.working then
		channel_id = data.S.selected_channel
	end
	---@cast channel_id channel_id
	
	channel_switch(data.entity, channel_id, data.entity.surface)
end

---@param surf_id surface_index
function M.on_surface_event(surf_id)
	local surf = storage.channels.surfaces[surf_id]
	if surf then
		-- delete surface data
		for id, _ in pairs(surf.channels) do
			destroy_hubs(surf, id)
		end
		storage.channels.surfaces[surf_id] = nil
	end
end

return M
