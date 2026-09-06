-- Point the projects picker (dashboard "p", <leader>fp) at ~/Projects.
--
-- snacks defaults `dev` to { "~/dev", "~/projects" } -- lowercase. Omarchy
-- provisions ~/Projects instead (omarchy-provision-user and
-- omarchy-upgrade-to-quattro create it and bookmark it in the file manager), so
-- on a case-sensitive filesystem the picker scans two directories that do not
-- exist. Its other source is git roots of recently opened files, which is empty
-- on a fresh install -- so the picker opens with nothing in it.
--
-- The legacy defaults are kept when present, but only when present: fd prints
-- "Search path ... is not a directory" for each missing one.
local dev = { "~/Projects" }

for _, dir in ipairs({ "~/dev", "~/projects" }) do
	if vim.fn.isdirectory(vim.fn.expand(dir)) == 1 then
		table.insert(dev, dir)
	end
end

return {
	"folke/snacks.nvim",
	opts = {
		picker = {
			sources = {
				projects = {
					dev = dev,
				},
			},
		},
	},
}
