"""Verify omarchy-hyprland-titlebars lifecycle and pointer gestures in an isolated nested Hyprland.

The candidate library is only ever loaded into the disposable nested compositor,
never into the parent session.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

source = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('library', type=Path, help='built titlebars.so to test')
parser.add_argument('--artifacts', type=Path, default=Path('/tmp/omarchy-hyprland-titlebars-verification'))
args = parser.parse_args()
args.library = args.library.resolve()
if not args.library.is_file():
  parser.error(f'{args.library} does not exist')
args.artifacts.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix='oht-') as scratch:
  scratch = Path(scratch)
  for kind, target in [('client-header', 'pointer-protocol.h'), ('private-code', 'pointer-protocol.c')]:
    subprocess.run(['wayland-scanner', kind, str(source / 'wlr-virtual-pointer-unstable-v1.xml'), str(scratch / target)], check=True)
  subprocess.run(['cc', str(source / 'pointer.c'), str(scratch / 'pointer-protocol.c'), '-I', str(scratch), '-lwayland-client', '-o', str(scratch / 'pointer')], check=True)
  config = scratch / 'hyprland.lua'
  config.write_text('''
hl.monitor({ output = "", mode = "1280x800@60", position = "0x0", scale = 1 })
hl.config({ general = { gaps_in = 8, gaps_out = 8, border_size = 2, resize_on_border = true }, animations = { enabled = false }, input = { follow_mouse = 0 }, misc = { disable_hyprland_logo = true, disable_splash_rendering = true } })
hl.window_rule({ name = "test-float", match = { class = ".*" }, float = true, size = { 600, 400 }, center = true })
if hl.plugin and hl.plugin.hyprbars then
  hl.config({ plugin = { hyprbars = {
    enabled = true, bar_height = 30, bar_color = "rgb(24283b)", bar_color_inactive = "rgb(1a1b26)", col = { text = "rgb(c0caf5)" },
    button_rounding = 4, bar_text_align = "left", bar_text_font = "Sans", bar_text_size = 12, bar_part_of_window = true,
    edge_snap = true, edge_threshold = 24, snap_gap = 8,
    on_double_click = [[hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle", window = "address:%WINDOW%" })']],
  } } })
  hl.plugin.hyprbars.add_button({ bg_color = "rgb(f7768e)", fg_color = "rgb(1a1b26)", size = 18, icon = "×", action = [[hyprctl dispatch 'hl.dsp.window.close({ window = "address:%WINDOW%" })']] })
end
''')
  parent_instances = json.loads(subprocess.check_output(['hyprctl', 'instances', '-j'], text=True))
  if len(parent_instances) != 1:
    raise RuntimeError('Verification expects exactly one parent compositor')
  parent_signature = parent_instances[0]['instance']
  parent_display = str(Path(os.environ['XDG_RUNTIME_DIR']) / parent_instances[0]['wl_socket'])
  env = dict(os.environ, XDG_RUNTIME_DIR=str(scratch), AQ_BACKEND='wayland', WAYLAND_DISPLAY=parent_display, HYPRLAND_NO_SD_NOTIFY='1', HYPRLAND_NO_SD_VARS='1')
  env.pop('HYPRLAND_INSTANCE_SIGNATURE', None)
  log = (args.artifacts / 'compositor.log').open('w')
  compositor = subprocess.Popen(['Hyprland', '--config', str(config)], env=env, stdout=log, stderr=log)
  terminal = None
  secondary = None

  def ctl(*argv):
    # Never let a plugin command reach the parent compositor.
    if argv[0] == 'plugin':
      signature = env.get('HYPRLAND_INSTANCE_SIGNATURE')
      if not signature or signature == parent_signature or env['XDG_RUNTIME_DIR'] != str(scratch):
        raise RuntimeError('Refusing to send a plugin command outside the nested compositor')
    result = subprocess.run(['hyprctl', *argv], env=env, capture_output=True, text=True, timeout=5, check=True)
    if result.stdout.startswith('Err') or "Couldn't" in result.stdout:
      raise RuntimeError(result.stdout)
    return result.stdout

  def client():
    return json.loads(ctl('clients', '-j'))[0]

  def pointer(commands):
    subprocess.run([str(scratch / 'pointer'), '1280', '800'], input='\n'.join(commands) + '\n', text=True, env=env, check=True, timeout=10)
    time.sleep(.15)

  def drag_to(x, y):
    window = client()
    start_x = window['at'][0] + min(window['size'][0] // 2, 220)
    start_y = window['at'][1] - 15
    commands = [f'move {start_x} {start_y}', 'wait 100', 'down', 'wait 120']
    for i in range(1, 21):
      commands += [f'move {round(start_x + (x - start_x) * i / 20)} {round(start_y + (y - start_y) * i / 20)}', 'wait 20']
    commands += ['wait 100', 'up']
    pointer(commands)
    return client()

  def capture(name):
    monitor = json.loads(ctl('monitors', '-j'))[0]['name']
    subprocess.run(['grim', '-o', monitor, str(args.artifacts / f'{name}.png')], env=env, check=True)

  try:
    for _ in range(80):
      if compositor.poll() is not None:
        raise RuntimeError('Isolated compositor exited; inspect compositor.log')
      try:
        instances = json.loads(ctl('instances', '-j'))
      except (ValueError, subprocess.SubprocessError):
        instances = []
      if instances:
        env['HYPRLAND_INSTANCE_SIGNATURE'] = instances[0]['instance']
        env['WAYLAND_DISPLAY'] = instances[0]['wl_socket']
        break
      time.sleep(.1)
    else:
      raise RuntimeError('Isolated compositor did not start')
    time.sleep(.2)
    terminal = subprocess.Popen(['foot', '--app-id=omarchy-titlebars-isolated-test', '--title=Titlebars — isolated verification', 'sleep', '90'], env=env, stdout=log, stderr=log)
    for _ in range(60):
      if json.loads(ctl('clients', '-j')):
        break
      time.sleep(.1)
    else:
      raise RuntimeError('Test client did not map')

    xp = Path('/usr/lib/omarchy-windows-xp/hyprbars.so')
    sequence = [args.library, args.library]
    if xp.exists():
      sequence = [xp, args.library, xp, args.library]
    for library in sequence:
      ctl('plugin', 'load', str(library))
      time.sleep(.15)
      for _ in range(3):
        ctl('reload')
        time.sleep(.1)
        if library == args.library:
          assert not ctl('configerrors').strip(), ctl('configerrors')
        assert compositor.poll() is None
        assert client()
      ctl('plugin', 'unload', str(library))
      time.sleep(.15)
      assert not json.loads(ctl('plugin', 'list', '-j'))
    print('PASS: repeated load/reload/unload, interleaved with the XP fork', flush=True)

    ctl('plugin', 'load', str(args.library))
    ctl('reload')
    time.sleep(.25)
    assert not ctl('configerrors').strip(), ctl('configerrors')
    original = client()
    events = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    events.connect(str(scratch / 'hypr' / env['HYPRLAND_INSTANCE_SIGNATURE'] / '.socket2.sock'))
    events.settimeout(.2)
    capture('floating')

    left = drag_to(1, 360)
    assert left['at'][0] <= 12 and 610 <= left['size'][0] <= 630, left
    capture('snap-left')
    right = drag_to(1278, 360)
    assert 640 <= right['at'][0] <= 656 and 610 <= right['size'][0] <= 630, right
    capture('snap-right')
    free = drag_to(650, 220)
    assert free['size'] == original['size'], (free, original)
    top = drag_to(650, 1)
    assert top['fullscreen'] == 1 and top['at'][1] >= 30, top
    capture('maximized')
    restored = drag_to(650, 220)
    assert restored['fullscreen'] == 0 and restored['size'] == original['size'], restored
    assert 205 <= restored['at'][1] <= 255, restored
    print('PASS: real pointer titlebar drag left/right, restore size, top maximize, drag-down restore', flush=True)

    window = client()
    x, y = window['at'][0] + 120, window['at'][1] - 15
    pointer([f'move {x} {y}', 'wait 450', 'down', 'up', 'wait 100', 'down', 'up'])
    assert client()['fullscreen'] == 1, client()
    print('PASS: titlebar double-click maximize', flush=True)
    messages = b''
    try:
      while chunk := events.recv(65536):
        messages += chunk
    except TimeoutError:
      pass
    events.close()
    text = messages.decode()
    for marker in [',left,', ',right,', ',maximize,', ',none,']:
      assert f'omarchy_snap_preview>>' in text and marker in text, (marker, text)
    (args.artifacts / 'events.log').write_text(text)
    print('PASS: snap preview events and release cleanup', flush=True)

    # Make dispatch deliberately slow, then focus another window after clicking.
    # Both double-click and button actions must keep the decoration owner.
    config.write_text(config.read_text().replace('hyprctl dispatch', 'sleep 0.6; hyprctl dispatch'))
    ctl('reload')
    first_address = client()['address']
    ctl('dispatch', f'hl.dsp.window.fullscreen({{ mode = "maximized", action = "unset", window = "address:{first_address}" }})')
    ctl('dispatch', f'hl.dsp.window.resize({{ x = 500, y = 350, window = "address:{first_address}" }})')
    ctl('dispatch', f'hl.dsp.window.move({{ x = 60, y = 320, window = "address:{first_address}" }})')
    secondary = subprocess.Popen(['foot', '--app-id=omarchy-titlebars-focus-race', '--title=Second window must stay unchanged', 'sleep', '90'], env=env, stdout=log, stderr=log)
    for _ in range(60):
      windows = json.loads(ctl('clients', '-j'))
      if len(windows) == 2:
        break
      time.sleep(.1)
    assert len(windows) == 2, windows
    second_address = next(window['address'] for window in windows if window['address'] != first_address)
    ctl('dispatch', f'hl.dsp.window.move({{ x = 690, y = 320, window = "address:{second_address}" }})')
    pointer(['move 180 305', 'wait 450', 'down', 'up', 'wait 100', 'down', 'up'])
    ctl('dispatch', f'hl.dsp.focus({{ window = "address:{second_address}" }})')
    time.sleep(.7)
    windows = {window['address']: window for window in json.loads(ctl('clients', '-j'))}
    assert windows[first_address]['fullscreen'] == 1 and windows[second_address]['fullscreen'] == 0, windows
    ctl('dispatch', f'hl.dsp.window.fullscreen({{ mode = "maximized", action = "unset", window = "address:{first_address}" }})')
    ctl('dispatch', f'hl.dsp.window.move({{ x = 60, y = 320, window = "address:{first_address}" }})')
    pointer(['move 540 305', 'wait 450', 'down', 'up'])
    ctl('dispatch', f'hl.dsp.focus({{ window = "address:{second_address}" }})')
    time.sleep(.7)
    remaining = json.loads(ctl('clients', '-j'))
    assert len(remaining) == 1 and remaining[0]['address'] == second_address, remaining
    print('PASS: delayed double-click and close target the clicked window after focus changes', flush=True)

    # A workspace-scoped bar must release its reserved space as soon as a
    # window joins tiling, without waiting for a compositor config reload.
    ctl('eval', 'hl.config({ plugin = { hyprbars = { workspace_tag = "floating-test" } } })')
    ctl('dispatch', f'hl.dsp.window.tag({{ tag = "+floating-test", window = "address:{second_address}" }})')
    ctl('dispatch', f'hl.dsp.window.float({{ action = "disable", window = "address:{second_address}" }})')
    time.sleep(.3)
    tiled = client()
    assert not tiled['floating'] and tiled['at'][1] < 30, tiled
    capture('workspace-tiled-no-titlebar')
    ctl('dispatch', f'hl.dsp.window.float({{ action = "enable", window = "address:{second_address}" }})')
    ctl('dispatch', f'hl.dsp.window.fullscreen({{ mode = "maximized", action = "set", window = "address:{second_address}" }})')
    time.sleep(.3)
    assert client()['at'][1] >= 30, client()
    ctl('dispatch', f'hl.dsp.window.tag({{ tag = "-floating-test", window = "address:{second_address}" }})')
    time.sleep(.3)
    assert client()['at'][1] < 30, client()
    capture('workspace-untagged-no-titlebar')
    print('PASS: workspace-scoped titlebars release space immediately when tiled or untagged', flush=True)
  finally:
    if secondary and secondary.poll() is None:
      secondary.terminate()
      secondary.wait(timeout=5)
    if terminal and terminal.poll() is None:
      terminal.terminate()
      terminal.wait(timeout=5)
    compositor.terminate()
    try:
      compositor.wait(timeout=5)
    except subprocess.TimeoutExpired:
      compositor.kill()
      compositor.wait()
    log.close()
