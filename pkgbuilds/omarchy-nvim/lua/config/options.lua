-- Options are automatically loaded before lazy.nvim startup.
require("config.remote_clipboard").setup()

vim.opt.relativenumber = false
vim.g.autoformat = false

-- Only preview completions inline when an AI source is actually installed.
-- LazyVim's ai_cmp routes AI suggestions through the completion menu and turns
-- on blink's ghost text to preview them; with no AI extra enabled that ghost
-- text just echoes buffer words back at you while you type. Off, the AI extras
-- use their own native inline suggestions instead, still accepted with <Tab>.
vim.g.ai_cmp = false
