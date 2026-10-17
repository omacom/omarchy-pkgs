local provider = assert(vim.env.TEST_PROVIDER)
local real_system, real_systemlist = vim.fn.system, vim.fn.systemlist
local real_executable, real_readfile = vim.fn.executable, vim.fn.readfile
local writes, reads, emitted, read_result, failed, write_failed

local function setup(env, options)
  for _, key in ipairs({ "SSH_CONNECTION", "SSH_TTY", "TMUX", "HERDR_PANE_ID", "WAYLAND_DISPLAY" }) do
    vim.env[key] = nil
  end
  for key, value in pairs(env) do vim.env[key] = value end
  vim.g.clipboard = nil
  vim.g.omarchy_remote_clipboard_sync = options and options.sync
  vim.g.omarchy_remote_clipboard_osc52 = options and options.osc52
  vim.opt.clipboard = options and options.clipboard or ""
  writes, reads, emitted = {}, {}, {}
  read_result, failed, write_failed = nil, false, false
  vim.fn.readfile = function(path, ...)
    if path:match("^/proc/") then return {} end
    return real_readfile(path, ...)
  end
  vim.fn.executable = function(cmd)
    if cmd == "tmux" or cmd == "wl-copy" or cmd == "wl-paste" then return 1 end
    return real_executable(cmd)
  end
  vim.fn.system = function(cmd, lines)
    writes[#writes + 1] = { cmd, vim.deepcopy(lines) }
    real_system({ "sh", "-c", write_failed and "exit 1" or "exit 0" })
    return ""
  end
  vim.fn.systemlist = function(cmd)
    if cmd[2] == "show-options" then
      real_system({ "sh", "-c", "exit 0" })
      return { "on" }
    end
    if cmd[2] == "display-message" then
      real_system({ "sh", "-c", failed and "exit 1" or "exit 0" })
      return { "buffer-test", "" }
    end
    reads[#reads + 1] = cmd
    real_system({ "sh", "-c", failed and "exit 1" or "exit 0" })
    return vim.deepcopy(read_result or {})
  end
  vim.api.nvim_ui_send = function(data) emitted[#emitted + 1] = data end
  -- A clipboard read must never reach Neovim's synchronous OSC 52 query.
  require("vim.ui.clipboard.osc52").paste = function() error("OSC 52 read attempted") end
  dofile(provider).setup()
  vim.cmd("unlet! g:loaded_clipboard_provider")
  vim.cmd("runtime autoload/provider/clipboard.vim")
end

local function equal(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. " != " .. vim.inspect(expected))
end
local function put_yank()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "probe" })
  vim.cmd("normal! gg0yy")
  -- Unnamed clipboard writes are deferred until the command loop returns.
  vim.cmd("redraw")
  local start = vim.uv.hrtime()
  vim.cmd("normal! p")
  assert((vim.uv.hrtime() - start) / 1e6 < 1000, "paste blocked")
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "probe", "probe" })
end

setup({})
assert(vim.g.clipboard == nil and vim.o.clipboard == "", "local config changed")
for _, env in ipairs({ { SSH_CONNECTION = "test" }, { SSH_TTY = "test" }, { HERDR_PANE_ID = "test" } }) do
  setup(env)
  assert(vim.o.clipboard == "unnamedplus")
  put_yank()
  assert(#emitted > 0 and emitted[1]:find("\27]52;c;", 1, true))
  assert(#reads == 0)
  equal(vim.g.clipboard.paste["*"](), { {}, "v" })
  for _, regtype in ipairs({ "v", "V", "\22" .. "3" }) do
    vim.g.clipboard.copy["*"]({ "abc" }, regtype)
    equal(vim.g.clipboard.paste["*"](), { { "abc" }, regtype })
  end
end
print("ok - local, SSH, SSH_TTY and Herdr setup; real yy/p; no OSC 52 reads; register types")

setup({ SSH_CONNECTION = "test" }, { sync = false, clipboard = "unnamed" })
assert(vim.o.clipboard == "unnamed")
setup({ SSH_CONNECTION = "test" }, { clipboard = "unnamed" })
assert(vim.o.clipboard:find("unnamedplus", 1, true) and vim.o.clipboard:find("unnamed,", 1, true))
vim.opt.clipboard = ""
assert(vim.o.clipboard == "", "user override must win")
setup({ SSH_CONNECTION = "test" }, { osc52 = false })
put_yank()
assert(#emitted == 0)
print("ok - sync and OSC 52 opt-outs; existing clipboard flags and subsequent overrides")

setup({ SSH_CONNECTION = "test", TMUX = "test" })
local large = { string.rep("x", 1024 * 1024 + 1) }
vim.g.clipboard.copy["+"](large, "v")
equal(writes[1], { { "tmux", "load-buffer", "-w", "-" }, large })
assert(#emitted == 0)
read_result = { "external buffer" }
equal(vim.g.clipboard.paste["+"](), read_result)
equal(reads[1], { "tmux", "save-buffer", "-b", "buffer-test", "-" })
failed = true
equal(vim.g.clipboard.paste["+"](), { large, "v" })
write_failed = true
vim.g.clipboard.copy["+"]({ "retry" }, "v")
assert(#emitted == 1)
print("ok - tmux large yanks, shared buffer reads, failed read and write fallbacks")

setup({ TMUX = "test" }, { osc52 = false })
put_yank()
assert(#writes == 0 and #reads == 0 and #emitted == 0)
setup({ TMUX = "test" })
failed = true
put_yank()
print("ok - tmux-only yanks and paste; opt-out does not read a stale tmux buffer")

setup({ HERDR_PANE_ID = "test", WAYLAND_DISPLAY = "test" })
vim.g.clipboard.copy["*"]({ "primary" }, "v")
equal(writes[1][1], { "wl-copy", "--sensitive", "--type", "text/plain", "--primary" })
read_result = { "from another app" }
equal(vim.g.clipboard.paste["*"](), read_result)
equal(reads[1], { "wl-paste", "--no-newline", "--primary" })
read_result = {}
equal(vim.g.clipboard.paste["*"](), {})
failed = true
equal(vim.g.clipboard.paste["*"](), { { "primary" }, "v" })
setup({ SSH_CONNECTION = "test", WAYLAND_DISPLAY = "test", TMUX = "test" })
vim.g.clipboard.copy["+"]({ "both" }, "v")
assert(#writes == 2)
read_result = { "both" }
equal(vim.g.clipboard.paste["+"](), { { "both" }, "v" })
equal(reads[1], { "tmux", "save-buffer", "-b", "buffer-test", "-" })
print("ok - Wayland primary, external, empty and failed reads; SSH prefers tmux")
