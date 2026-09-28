-- Copies reach the local Wayland clipboard and attached terminals. Reads use
-- Wayland or tmux's buffer, falling back to this Neovim's last copy. Never query
-- the terminal with OSC 52: support for writes does not imply permission to read,
-- and an unanswered query blocks ordinary paste for ten seconds. To insert new
-- text from the host when no readable clipboard exists, use terminal paste.
local M = {}

local function proc_lines(pid, file)
  local ok, lines = pcall(vim.fn.readfile, "/proc/" .. pid .. "/" .. file)
  return ok and lines or {}
end

local function proc_ppid(pid)
  for _, line in ipairs(proc_lines(pid, "status")) do
    local ppid = line:match("^PPid:%s+(%d+)")
    if ppid then
      return tonumber(ppid)
    end
  end
end

local function ancestor_process_named(name)
  local pid = vim.fn.getpid()

  for _ = 1, 16 do
    local ppid = proc_ppid(pid)
    if not ppid or ppid <= 1 then
      return false
    end

    local comm = proc_lines(ppid, "comm")[1] or ""
    if comm:find(name, 1, true) then
      return true
    end

    pid = ppid
  end

  return false
end

function M.setup()
  local in_tmux = vim.env.TMUX ~= nil
  local in_ssh = vim.env.SSH_TTY ~= nil or vim.env.SSH_CONNECTION ~= nil
  local in_herdr = vim.env.HERDR_PANE_ID ~= nil or ancestor_process_named("herdr")

  if not (in_tmux or in_ssh or in_herdr) then
    return
  end

  local osc52 = require("vim.ui.clipboard.osc52")
  local has_wayland = vim.env.WAYLAND_DISPLAY ~= nil
    and vim.fn.executable("wl-copy") == 1
    and vim.fn.executable("wl-paste") == 1

  local has_tmux = in_tmux and vim.fn.executable("tmux") == 1
  local last_copy = {}

  local function tmux_export_enabled()
    local setting = vim.fn.systemlist({ "tmux", "show-options", "-sv", "set-clipboard" })
    return vim.v.shell_error == 0 and (setting[1] == "on" or setting[1] == "external")
  end

  local function copy(register)
    local emit = osc52.copy(register)

    return function(lines, regtype)
      last_copy[register] = { vim.deepcopy(lines), regtype }

      if has_wayland then
        local cmd = { "wl-copy", "--sensitive", "--type", "text/plain" }
        if register == "*" then
          cmd[#cmd + 1] = "--primary"
        end
        vim.fn.system(cmd, lines)
      end

      if vim.g.omarchy_remote_clipboard_osc52 ~= false then
        if has_tmux and register == "+" then
          -- tmux ignores zero-byte loads. Record the current buffer's identity
          -- instead: all Neovim instances see empty until a new buffer arrives,
          -- without deleting the user's shared tmux clipboard history.
          if #lines == 0 or (#lines == 1 and lines[1] == "") then
            vim.fn.system({ "tmux", "set-option", "-sF", "@omarchy-nvim-cleared-buffer", "#{buffer_name}" })
            return
          end
          -- Let tmux emit OSC 52, avoiding its input parser's payload size limit.
          -- Explicit -w bypasses set-clipboard, so honor the user's policy first.
          local cmd = { "tmux", "load-buffer" }
          if tmux_export_enabled() then
            cmd[#cmd + 1] = "-w"
          end
          cmd[#cmd + 1] = "-"
          vim.fn.system(cmd, lines)
          if vim.v.shell_error == 0 then
            return
          end
        end
        emit(lines)
      end
    end
  end

  local function paste(register)
    return function()
      local cmd
      -- tmux's buffer is shared between Neovim instances on the server. Over
      -- SSH, prefer it to the remote machine's unrelated graphical clipboard.
      if has_tmux and register == "+" and (in_ssh or not has_wayland)
        and vim.g.omarchy_remote_clipboard_osc52 ~= false then
        local buffers = vim.fn.systemlist({ "tmux", "display-message", "-p",
          "#{buffer_name}\n#{@omarchy-nvim-cleared-buffer}" })
        if vim.v.shell_error ~= 0 then
          return vim.deepcopy(last_copy[register] or { {}, "v" })
        end
        if not buffers[1] or buffers[1] == "" or buffers[1] == buffers[2] then
          return { {}, "v" }
        end
        -- Pin the buffer selected above: a concurrent copy must not change
        -- which payload we read after checking its identity against the marker.
        cmd = { "tmux", "save-buffer", "-b", buffers[1], "-" }
      elseif has_wayland then
        cmd = { "wl-paste", "--no-newline" }
        if register == "*" then
          cmd[#cmd + 1] = "--primary"
        end
      end

      if cmd then
        local lines = vim.fn.systemlist(cmd, "", 1)
        if vim.v.shell_error == 0 then
          -- An empty clipboard is valid; only failed reads use the fallback.
          if last_copy[register] and vim.deep_equal(lines, last_copy[register][1]) then
            return vim.deepcopy(last_copy[register])
          end
          return lines
        end
      end

      return vim.deepcopy(last_copy[register] or { {}, "v" })
    end
  end

  vim.g.clipboard = {
    name = "OmarchyRemoteClipboard",
    copy = { ["+"] = copy("+"), ["*"] = copy("*") },
    paste = { ["+"] = paste("+"), ["*"] = paste("*") },
    cache_enabled = 0,
  }

  -- LazyVim clears this over SSH. Users can opt out before setup or override
  -- the option afterward in config/options.lua.
  if vim.g.omarchy_remote_clipboard_sync ~= false then
    vim.opt.clipboard:append("unnamedplus")
  end
end

return M
