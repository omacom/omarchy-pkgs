-- Make highlight groups transparent while preserving their other attributes
local function make_transparent(name)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	if ok then
		hl.bg = nil
		vim.api.nvim_set_hl(0, name, hl)
	end
end

local groups = {
	-- transparent background
	"Normal",
	"NormalFloat",
	"FloatBorder",
	"Pmenu",
	"Terminal",
	"EndOfBuffer",
	"FoldColumn",
	"Folded",
	"SignColumn",
	"LineNr",
	"CursorLineNr",
	"StatusLine",
	"StatusLineNC",
	"NormalNC",
	"WhichKeyFloat",
	"TelescopeBorder",
	"TelescopeNormal",
	"TelescopePromptBorder",
	"TelescopePromptTitle",
	-- neotree
	"NeoTreeNormal",
	"NeoTreeNormalNC",
	"NeoTreeVertSplit",
	"NeoTreeWinSeparator",
	"NeoTreeEndOfBuffer",
	-- nvim-tree
	"NvimTreeNormal",
	"NvimTreeVertSplit",
	"NvimTreeEndOfBuffer",
	-- notify
	"NotifyINFOBody",
	"NotifyERRORBody",
	"NotifyWARNBody",
	"NotifyTRACEBody",
	"NotifyDEBUGBody",
	"NotifyINFOTitle",
	"NotifyERRORTitle",
	"NotifyWARNTitle",
	"NotifyTRACETitle",
	"NotifyDEBUGTitle",
	"NotifyINFOBorder",
	"NotifyERRORBorder",
	"NotifyWARNBorder",
	"NotifyTRACEBorder",
	"NotifyDEBUGBorder",
}

-- The current line goes see-through too, leaving its number to mark it. The
-- file tree marks its selection with that line alone, so it keeps the colour.
local cursorline = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false })
if cursorline.bg then
	vim.api.nvim_set_hl(0, "NeoTreeCursorLine", { bg = cursorline.bg })
end
table.insert(groups, "CursorLine")

for _, name in ipairs(groups) do
	make_transparent(name)
end

-- Themes like Gruvbox link the focused Snacks result to CursorLine.
-- Fall back to the theme's selection color if that highlight is transparent.
local picker_cursorline = "SnacksPickerListCursorLine"
local picker_hl = vim.api.nvim_get_hl(0, { name = picker_cursorline, link = false })
if not picker_hl.bg and not picker_hl.reverse then
  vim.api.nvim_set_hl(0, picker_cursorline, { link = "Visual" })
end
