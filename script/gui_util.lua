---@class GuiDef
---@field type string
---@field [string] any
---@field style? StyleDef|string
---@field children? GuiDef[]

---@class StyleDef
---@field base? string
---@field [string] any

---@alias GuiRefs table<string, LuaGuiElement>

local GuiDef = {}
GuiDef.__index = GuiDef

---@param children GuiDef[]
---@return GuiDef
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
---@return LuaGuiElement, GuiRefs
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
