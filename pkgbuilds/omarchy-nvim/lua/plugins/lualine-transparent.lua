-- Let the status line show the terminal background, like the rest of the
-- editor. Lualine's auto theme paints its middle sections a solid colour, so
-- they are cleared on each theme it builds, which it does again on every
-- colorscheme change. The mode and position sections keep their colours.
return {
	"nvim-lualine/lualine.nvim",
	opts = function(_, opts)
		opts.options = opts.options or {}
		opts.options.theme = function()
			local theme = require("lualine.utils.loader").load_theme("auto")
			for _, mode in pairs(theme) do
				for _, section in ipairs({ "b", "c" }) do
					if mode[section] then
						mode[section].bg = "None"
					end
				end
			end
			return theme
		end
	end,
}
