---@class SurfaceChannels
---@field nextpos number
---@field channels table<string, Channel>
---@field hubs LuaEntity[]

---@class Channel
---@field hub LuaEntity
---@field link_hub LuaEntity
---@field is_interplanetary boolean

local M = {}

-- simply re-link all link hubs of this channel on all registered surfaces
-- could be optimized by using actual linked list logic, list of surfaces with radars will be small
---@param channel_name string
local function update_channel_surface_links(channel_name)
	--game.print(">> update_channel_surface_links: ".. channel_name)
	
	local prevR = nil
	local prevG = nil
	for _, surfch in pairs(storage.chsurfaces) do
		local channel = surfch.channels[channel_name]
		if channel then
			local h = channel.hub.get_wire_connectors(true)
			local l = channel.link_hub.get_wire_connectors(true)
			
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
---@param channel Channel
local function set_is_interplanetary(channel)
	local a = channel.hub.get_wire_connectors(true)
	local b = channel.link_hub.get_wire_connectors(true)
	if channel.is_interplanetary then
		a[W.circuit_red  ].connect_to(b[W.circuit_red  ], false, HIDDEN)
		a[W.circuit_green].connect_to(b[W.circuit_green], false, HIDDEN)
	else
		a[W.circuit_red  ].disconnect_from(b[W.circuit_red  ], HIDDEN)
		a[W.circuit_green].disconnect_from(b[W.circuit_green], HIDDEN)
	end
end

---@param surface LuaSurface
local function init_surf_data(surface)
	-- lazily create surface data
	local surfch = storage.chsurfaces[surface.index]
	if not surfch then
		surfch = { nextpos=0, channels={}, hubs={} }
		storage.chsurfaces[surface.index] = surfch
	end
	return surfch
end
-- init channel for surface, if the same channel also gets created on other surface, their link_hub will be connected
---@param surfch SurfaceChannels
---@param channel_name string
---@param surface LuaSurface
local function init_channel(surfch, channel_name, surface)
	-- lazily create channel data
	local channel = surfch.channels[channel_name]
	if not channel then
		-- Hub to directly connect all radars that have this channel selected to
		-- Switching radar channel is now O(1)!
		-- If mod deinstalled, this hub disappears and automatically removes all hidden radar wires (and vanilla links reappear)!
		local hub = surface.create_entity{
			name="hexcoder_radar_uplink-cc", force="player",
			position={surfch.nextpos+0.5, 0.5}, snap_to_grid=false
		} ---@cast hub -nil
		hub.destructible = false
		hub.combinator_description = "Radar signal radar hub :".. surface.name ..":".. channel_name
		
		-- Interplanetary link hub, which connect connect in chain to same hub on all other surfaces
		-- Switching a channel interplanetary status is now O(1)!
		-- update_channel_surface_links() now only needs to be called on surface create/destroy!
		-- (If single hub existed, update_channel_surface_links() would need to be called on interplanetary toggle, and may have to iterate countless radar wires to find ones to remove)
		local link_hub = surface.create_entity{
			name="hexcoder_radar_uplink-cc", force="player",
			position={surfch.nextpos+0.5, 1.5}, snap_to_grid=false
		} ---@cast link_hub -nil
		link_hub.destructible = false
		link_hub.combinator_description = "Radar signal surface hub :".. surface.name ..":".. channel_name
		
		local interplanetary = channel_name ~= "_global"
		
		channel = { hub=hub, link_hub=link_hub, is_interplanetary=interplanetary }
		surfch.channels[channel_name] = channel
		--if debug then
			surfch.nextpos = surfch.nextpos + 1
		--end
		
		update_channel_surface_links(channel_name)
		
		set_is_interplanetary(channel)
	end
	
	return channel
end
---@param surfch SurfaceChannels
---@param channel_name string
local function destroy_channel(surfch, channel_name)
	--game.print(">> destroy_channel: ".. serpent.block({ surfch, channel_name }))
	local channel = surfch.channels[channel_name]
	
	channel.hub.destroy()
	channel.link_hub.destroy()
	
	surfch.channels[channel_name] = nil
	
	-- fix broken link
	update_channel_surface_links(channel_name)
end

---@param surfch SurfaceChannels
local function leave_channel(surfch, old_hub)
	-- delete hubs for channels once channel no longer used by using wires at hub as refcount
	-- alternatively just make user delete old channels via gui?
	-- TODO: test this
	--if old_hub then
	--	local conR = old_hub.get_wire_connectors(true)[R]
	--	if conR.connection_count <= 2 then -- max 2 surface links in chain
	--		if conR.connections[1].target.owner.name == "hexcoder_radar_uplink-cc" and conR.connections[2] and
	--		   conR.connections[2].target.owner.name == "hexcoder_radar_uplink-cc" then
	--			-- connection now useless
	--			local name = surfch.hubs[old_hub.unit_number]
	--			--surfch.hubs[ch_hub.unit_number] = nil
	--			--surfch.channels[name] = nil
	--			--
	--			--old_hub.destroy()
	--			destroy_channel(...)
	--		end
	--	end
	--end
end
---@param entity LuaEntity
---@param channel_name string
---@param surface LuaSurface
local function channel_switch(entity, channel_name, surface)
	--game.print(">> channel_switch: ".. serpent.line({ entity, channel_name, surface }))
	
	-- true: create connector: if no current connections, would otherwise return nil
	local conR = entity.get_wire_connectors(true)[W.circuit_red]
	local conG = entity.get_wire_connectors(true)[W.circuit_green]
	
	local old_hub = nil
	for _, c in ipairs(conR.connections) do
		if c.origin == HIDDEN and (c.target.owner.name == "hexcoder_radar_uplink-cc") then
				--or c.target.owner.name == "radar") then --dbg
			conR.disconnect_from(c.target, HIDDEN)
			old_hub = c.target.owner
		end
	end
	for _, c in ipairs(conG.connections) do
		if c.origin == HIDDEN and (c.target.owner.name == "hexcoder_radar_uplink-cc") then
				--or c.target.owner.name == "radar") then --dbg
			conG.disconnect_from(c.target, HIDDEN)
		end
	end
	--conR.disconnect_all(defines.wire_origin.script) --dbg
	--conG.disconnect_all(defines.wire_origin.script) --dbg
	
	local surfch = init_surf_data(surface)
	
	leave_channel(surfch, old_hub)
	
	if channel_name then
		-- enter channel
		local channel = init_channel(surfch, channel_name, surface)
		
		local cc = channel.hub.get_wire_connectors(true)
		conR.connect_to(cc[W.circuit_red  ], false, HIDDEN)
		conG.connect_to(cc[W.circuit_green], false, HIDDEN)
	end
end
---@param entity LuaEntity
function M.update_radar_channel(entity)
	local data = storage.radars[entity.unit_number]
	--game.print(">> update_radar_channel: ".. serpent.block(data))
	
	local channel_name
	if data and data.S.mode ~= nil then
		channel = nil
		--channel_name = "interplanetary1"
	else
		channel_name = "_global"
	end
	
	channel_switch(entity, channel_name, entity.surface)
end

--@param surf_id surface_index
--@param surface LuaSurface
function M.on_surface_event(surf_id, surface)
	local surfch = storage.chsurfaces[surf_id]
	if surfch then
		-- delete surface data
		for channel_name, _ in pairs(surfch.channels) do
			destroy_channel(surfch, channel_name)
		end
		storage.chsurfaces[surf_id] = nil
	end
	
	if surface then -- on_surface_deleted surface is already deleted
		local radars = surface.find_entities_filtered{ type="radar", name="radar" }
		for _, radar in ipairs(radars) do
			M.update_radar_channel(radar)
		end
	end
end

return M
