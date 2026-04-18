---@class GuiDef
---@field type string
---@field [string] any
---@field style? StyleDef|string
---@field children? GuiDef[]

---@class StyleDef
---@field base? string
---@field [string] any

---@alias GuiRefs table<string, LuaGuiElement>

-- Using globals here because it is annoying to import everything, probably should not be doing that?

local M = {}

local GuiDef = {}
GuiDef.__index = GuiDef

---@param children GuiDef[]
---@return GuiDef def
function GuiDef:add(children)
	local list = self.children or {}
	for _, c in ipairs(children) do
		table.insert(list, c)
	end
	self.children = list
	return self
end

local _gui_non_args = {children=true, drag_target=true}

---@param parent LuaGuiElement
---@param name? string
---@return LuaGuiElement elem, GuiRefs named_refs
function GuiDef:add_to(parent, name, refs)
	refs = refs or {}
	
	local args = {}
	for k, v in pairs(self) do
		if _gui_non_args[k] then
			-- ignore
		else
			args[k] = v
		end
	end
	
	-- if style=<string> keep it as is (no style_mods)
	-- if style=<table> set style.base in LuaGuiElement.add rest via LuaGuiElement.style.key = value
	local style_mods
	if type(self.style) == "table" then -- style
		style_mods = self.style
		args.style = style_mods.base
	end
	
	-- allow name override
	if name then
		args.name = name
	end
	
	local elem = parent.add(args)
	
	-- remember any named gui element (assume names are unique)
	if args.name then
		refs[args.name] = elem
	end
	-- drag_target string->LuaGuiElement
	if self.drag_target then
		elem.drag_target = refs[self.drag_target]
	end
	
	if style_mods then
		for k, v in pairs(style_mods) do
			if k ~= "base" then -- filter out base here to avoid having to modify original table
				elem.style[k] = v
			end
		end
	end
	
	-- add children recursively
	if self.children then
		for _, child in ipairs(self.children) do
			child:add_to(elem, nil, refs)
		end
	end
	
	return elem, refs
end

---@param args GuiDef
---@return GuiDef
function GUI(args)
	return setmetatable(args, GuiDef)
end

---@param name string
---@param caption LocalisedString
---@param content GuiDef[]
---@return GuiDef
function gui_default_frame(name, caption, content)
	-- TODO: cursor is not finger pointer on draggable titlebar like with built in guis?
	return GUI{type="frame", name=name, direction="vertical"}:add{
		GUI{type="flow", drag_target=name, style={horizontal_spacing=8}}:add{
			GUI{type="label", caption=caption, style={base="frame_title", top_margin=-3, bottom_margin=3}, ignored_by_interaction=true},
			GUI{type="empty-widget", style={base="draggable_space_header", height=24, right_margin=4, horizontally_stretchable=true}, ignored_by_interaction=true},
			GUI{type="sprite-button", name=name.."-window_close_button", style="close_button", sprite="utility/close"}
		},
	}:add(content)
end

function gui_vpane(name, style)
	local actual_style={base="inside_shallow_frame_with_padding"}
	if style then
		for k,v in pairs(style) do actual_style[k] = v end
	end
	return GUI{type="frame", name=name, direction="vertical", style=actual_style}
end
function gui_hflow(args)
	return GUI{type="flow", name=args.name, direction="horizontal", style=args.style}
end
function gui_vflow(args)
	return GUI{type="flow", name=args.name, direction="vertical", style=args.style}
end

-- update radiobutton state on click 
---@generic Mode : string
---@param refs GuiRefs
---@param modes table<string, Mode> gui element name to mode name
---@param clicked_element? string gui element name that was clicked (can be related) or nil
---@return Mode selected the mode that still is or was just selected, defaults to the first 
function update_radiobutton(refs, modes, clicked_element)
	local clicked_mode = modes[clicked_element] -- clicked radio button -> set mode
	if clicked_mode then
		for k,m in pairs(modes) do
			refs[k].state = clicked_mode == m -- update all radio button states
		end
		return clicked_mode
	else
		for k,m in pairs(modes) do
			if refs[k].state then
				return m
			end
		end
		--return nil
		-- default to first
		for k,m in pairs(modes) do
			refs[k].state = true
			return m
		end
	end
end

---@alias Item table|userdata

---@class ArrayList
---@field [integer] Item -- T[] (continuous array)
---@field [Item] integer -- table<T, integer> (index lookup)
local ArrayList = {}
ArrayList.__index = ArrayList

---@return ArrayList
function ArrayList.new()
	return setmetatable({}, ArrayList)
end

---@generic T : table
---@param self ArrayList
---@param item Item
function ArrayList:add(item)
	assert(self[item] == nil)
	local idx = #self + 1
	self[idx] = item ; self[item] = idx
end
---@generic T : table
---@param self ArrayList
---@param item Item
---@return boolean was_added
function ArrayList:try_add(item)
	if self[item] ~= nil then return false end
	local idx = #self + 1
	self[idx] = item ; self[item] = idx
	return true
end

---@generic T : table
---@param self ArrayList
---@param item Item
function ArrayList:remove(item)
	-- delete by swap with last
	local last_idx = #self
	local idx  = self[item]     ; self[item] = nil
	local last = self[last_idx] ; self[last_idx] = nil
	self[idx] = last ; self[last] = idx
end
---@generic T : table
---@param self ArrayList
---@param item Item
---@return boolean was_removed
function ArrayList:try_remove(item)
	if not self[item] then return false end
	-- delete by swap with last
	local last_idx = #self
	local idx  = self[item]     ; self[item] = nil
	local last = self[last_idx] ; self[last_idx] = nil
	self[idx] = last ; self[last] = idx
	return true
end

local ceil = math.ceil

---@generic T : Item
---@class TickList<T> : ArrayList
---@field cur integer
local TickList = {}
TickList.__index = TickList
TickList.add = ArrayList.add
TickList.remove = ArrayList.remove

---@return TickList
function TickList.new()
	return setmetatable({ cur=1 }, TickList)
end

---@param self TickList
---@param game_tick integer
---@param period integer
---@param func fun(item)
function TickList:stagger_tick(game_tick, period, func)
	-- update each entity exactly once every period
	-- should be safe to remove items or change period without updating poll_cur, but could cause skipping of items for one period
	local ratio = (game_tick % period) + 1 -- +1 only works with tick freq=1, period must be divisible by this, so 1 is good
	local last = ceil((ratio / period) * #self)
	
	for i=self.cur,last do
		func(self[i])
	end
	
	if ratio == period then self.cur = 1-- end of list reached
	else                    self.cur = last+1 end
end

M.ArrayList = ArrayList
M.TickList = TickList
return M