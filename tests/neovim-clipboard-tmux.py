#!/usr/bin/env python3
"""Exercise the provider against real, isolated tmux buffers and fake terminals."""
import base64
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parents[1]
PROVIDER = ROOT / "pkgbuilds/omarchy-nvim/lua/config/remote_clipboard.lua"


def drain(fd, seconds=0.1):
    data = b""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if select.select([fd], [], [], max(0, deadline - time.monotonic()))[0]:
            try:
                data += os.read(fd, 65536)
            except OSError:
                break
    return data


with tempfile.TemporaryDirectory(prefix="nvim-tmux-test-") as directory:
    root = Path(directory)
    command = ["tmux", "-S", str(root / "socket"), "-f", "/dev/null"]
    clients = []

    def tmux(*args):
        return subprocess.check_output(command + list(args), text=True)

    driver = root / "driver.lua"
    driver.write_text(r'''
local request = vim.json.decode(table.concat(vim.fn.readfile(vim.env.TEST_REQUEST), "\n"))
dofile(vim.env.TEST_PROVIDER).setup()
if request.operation == "copy" then
  vim.fn.setreg("+", request.lines, request.regtype or "v")
else
  local value = vim.g.clipboard.paste["+"]()
  local lines = type(value[1]) == "table" and value[1] or value
  io.write(vim.json.encode(lines))
end
''')

    def nvim(operation, lines=None, regtype="v"):
        request = root / "request.json"
        request.write_text(json.dumps(dict(operation=operation, lines=lines, regtype=regtype)))
        env = dict(os.environ)
        for key in ("WAYLAND_DISPLAY", "DISPLAY", "HERDR_PANE_ID", "SSH_TTY"):
            env.pop(key, None)
        env.update(
            TMUX=tmux("display-message", "-p", "#{socket_path},#{pid},0").strip(),
            TMUX_PANE=tmux("display-message", "-p", "-t", "A:0.0", "#{pane_id}").strip(),
            SSH_CONNECTION="test", TEST_PROVIDER=str(PROVIDER),
            TEST_REQUEST=str(request),
        )
        result = subprocess.run(
            ["nvim", "--clean", "-n", "--headless", "-i", "NONE", "-l", str(driver)],
            env=env, cwd=root, capture_output=True, text=True, timeout=15,
        )
        assert result.returncode == 0, result.stderr
        if operation == "paste":
            return json.loads(result.stdout)

    try:
        tmux("new-session", "-d", "-s", "A")
        tmux("new-session", "-d", "-s", "B")
        tmux("set-option", "-s", "terminal-features", "xterm*:clipboard")
        tmux("set-option", "-g", "set-clipboard", "off")
        # Every nvim() call is a separate instance: clearing must be shared.
        nvim("copy", [""])
        assert nvim("paste") == [], "empty server clipboard did not stay empty"
        tmux("set-buffer", "older history")
        nvim("copy", ["private previous value"])
        assert nvim("paste") == ["private previous value"]
        history = tmux("list-buffers")
        for _ in range(2):
            nvim("copy", [""])
            assert nvim("paste") == [], "clear returned stale clipboard text"
        assert tmux("list-buffers") == history, "clear destroyed tmux history"
        tmux("set-buffer", "external copy")
        assert nvim("paste") == ["external copy"], "new copy did not supersede clear"
        nvim("copy", [""])
        nvim("copy", ["new Neovim copy"])
        assert nvim("paste") == ["new Neovim copy"]
        print("ok - shared empty clipboard, preserved history, and subsequent copies")

        for lines, regtype in [(["line"], "V"), (["a", "b"], "v"),
                               (["x" * (1024 * 1024 + 1)], "v"),
                               (["$(touch NEVER) `id`; quotes ' \"", "λ\u001b\n"], "v")]:
            nvim("copy", lines, regtype)
            # Neovim represents embedded NUL bytes as newline inside a list item.
            expected = list(lines)
            if regtype == "V":
                expected.append("")
            actual = nvim("paste")
            assert actual == expected, ("transport changed clipboard bytes", repr(actual)[:200], repr(expected)[:200])
        assert not (root / "NEVER").exists(), "clipboard content executed as shell code"
        print("ok - real transport: linewise, multiline, large and literal/control payloads")

        # Attach three PTYs, never the developer's terminal or clipboard.
        for session in ("A", "A", "B"):
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))

            def controlling_tty():
                os.setsid()
                fcntl.ioctl(0, termios.TIOCSCTTY, 0)

            env = dict(os.environ, TERM="xterm-256color")
            env.pop("TMUX", None)
            env.pop("TMUX_PANE", None)
            process = subprocess.Popen(
                command + ["attach-session", "-t", session], stdin=slave,
                stdout=slave, stderr=slave, env=env, preexec_fn=controlling_tty,
            )
            os.close(slave)
            clients.append((master, process))
            drain(master)
        for policy in ("off", "on", "external", "off"):
            tmux("set-option", "-s", "set-clipboard", policy)
            for fd, _ in clients:
                drain(fd)
            payload = "synthetic-export-" + policy
            nvim("copy", [payload])
            outputs = [drain(fd, 0.3) for fd, _ in clients]
            exports = [b"\x1b]52;" in output for output in outputs]
            assert not exports[2], "clipboard escaped into an unrelated session"
            if policy == "off":
                assert not any(exports), "set-clipboard off leaked OSC 52"
            else:
                assert sum(exports[:2]) == 1, "expected one selected tmux client"
                assert any(base64.b64encode(payload.encode()) in output for output in outputs[:2])
            assert nvim("paste") == [payload], "export policy broke internal paste"
        print("ok - real clients: export policy, policy changes, selected-client isolation")
    finally:
        subprocess.run(command + ["kill-server"], capture_output=True)
        for fd, process in clients:
            process.wait(timeout=5)
            os.close(fd)
