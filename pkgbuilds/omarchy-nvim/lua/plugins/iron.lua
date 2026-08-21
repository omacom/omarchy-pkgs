return {
  "Vigemus/iron.nvim",
  cmd = { "IronRepl", "IronRestart", "IronFocus", "IronHide" },
  keys = {
    { "<leader>r", desc = "+repl" },
    { "<leader>rr", "<cmd>IronRepl<cr>", desc = "Toggle REPL" },
    { "<leader>rR", "<cmd>IronRestart<cr>", desc = "Restart REPL" },
    { "<leader>rf", "<cmd>IronFocus<cr>", desc = "Focus REPL" },
    { "<leader>rh", "<cmd>IronHide<cr>", desc = "Hide REPL" },
    { "<leader>rs", desc = "+send" },
    { "<leader>rsl", "<cmd>lua require('iron.core').send_line()<cr>", desc = "Send Line" },
    { "<leader>rsf", "<cmd>lua require('iron.core').send_file()<cr>", desc = "Send File" },
    { "<leader>rsp", "<cmd>lua require('iron.core').send_paragraph()<cr>", desc = "Send Paragraph" },
    { "<leader>rsu", "<cmd>lua require('iron.core').send_until_cursor()<cr>", desc = "Send Until Cursor" },
    { "<leader>rsb", "<cmd>lua require('iron.core').send_code_block(false)<cr>", desc = "Send Code Block" },
    { "<leader>rsn", "<cmd>lua require('iron.core').send_code_block(true)<cr>", desc = "Send Code Block & Move Next" },
    { "<leader>rsm", "<cmd>lua require('iron.core').run_motion('send_motion')<cr>", desc = "Send Motion" },
    { "<leader>rs", "<cmd>lua require('iron.core').visual_send()<cr>", mode = "v", desc = "Send Selection" },
    { "<leader>rsv", "<cmd>lua require('iron.core').visual_send()<cr>", mode = "v", desc = "Send Selection" },
    { "<leader>rm", desc = "+marks" },
    { "<leader>rmm", "<cmd>lua require('iron.core').run_motion('mark_motion')<cr>", desc = "Mark Motion" },
    { "<leader>rmv", "<cmd>lua require('iron.core').mark_visual()<cr>", mode = "v", desc = "Mark Visual" },
    { "<leader>rmd", "<cmd>lua require('iron.marks').drop_last()<cr>", desc = "Remove Mark" },
    { "<leader>rmr", "<cmd>lua require('iron.core').send_mark()<cr>", desc = "Send Mark" },
    { "<leader>rq", "<cmd>lua require('iron.core').send(nil, string.char(03))<cr>", desc = "Interrupt REPL" },
    { "<leader>rx", "<cmd>lua require('iron.core').close_repl()<cr>", desc = "Exit REPL" },
    { "<leader>rcc", "<cmd>lua require('iron.core').send(nil, string.char(12))<cr>", desc = "Clear REPL" },
    { "<leader>rcl", "<cmd>lua require('iron.marks').clear_hl()<cr>", desc = "Clear Highlight" },
  },
  opts = function()
    local python_cmd = vim.fn.executable("ipython") == 1 and { "ipython", "--no-autoindent" } or { "python3" }
    local sh_cmd = vim.fn.executable("zsh") == 1 and { "zsh" } or { vim.env.SHELL or "bash" }

    return {
      config = {
        scratch_repl = true,
        repl_definition = {
          sh = {
            command = sh_cmd,
            block_dividers = { "# %%" },
          },
          python = {
            command = python_cmd,
            format = function(lines, extras)
              local result = require("iron.fts.common").bracketed_paste_python(lines, extras)
              return vim.tbl_filter(function(line)
                return not string.match(line, "^%s*#")
              end, result)
            end,
            block_dividers = { "# %%", "#%%" },
          },
        },
        repl_filetype = function(bufnr, ft)
          return ft
        end,
        repl_open_cmd = "vertical split",
      },
      highlight = {
        italic = true,
      },
      ignore_blank_lines = true,
    }
  end,
  config = function(_, opts)
    require("iron.core").setup(opts)
    vim.keymap.set("t", "<esc>", "<C-\\><C-n>", { desc = "Exit terminal mode" })
  end,
}
