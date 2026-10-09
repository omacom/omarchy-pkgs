# omarchy-hyprland-titlebars

A native Hyprland plugin that gives Omarchy's floating workspace mode its window titlebars and edge snapping. It draws theme-neutral titlebars on floating windows and snaps a dragged window to the left or right half of the monitor, or maximizes it at the top edge.

Omarchy core has no build step, so the plugin ships as its own package, built here alongside Hyprland. Omarchy loads it from its Lua config only while a workspace floats, from a fixed path:

```lua
hl.plugin.load("/usr/lib/omarchy-hyprland-titlebars/titlebars.so")
```

That path is a contract with Omarchy core. The plugin still registers itself with Hyprland as `hyprbars` and keeps the `hl.plugin.hyprbars.add_button()` Lua interface and the `plugin.hyprbars.*` options, because Omarchy's config is written against those names.

## Origin and license

This is a fork of Hypr Development's [BSD-licensed hyprbars](https://github.com/hyprwm/hyprland-plugins/tree/main/hyprbars). The source was adapted from the Omarchy Windows 98 theme's `vendor/hyprbars` fork ([theme project](https://github.com/omacom/omarchy-98-theme)), which supplies Hyprland 0.56 Lua API support and safe coexistence with the earlier Windows XP fork. Colors, font, rounding, and actions are supplied by Omarchy's configuration; no theme styling is embedded in the renderer.

The original hyprbars license is in `LICENSE` (BSD-3-Clause). Omarchy's changes are under the MIT license in `LICENSE.MIT`. The package installs both under `/usr/share/licenses/omarchy-hyprland-titlebars/`.

## Added options

These are in addition to the upstream `plugin.hyprbars` titlebar settings.

| Option | Default | Behavior |
| --- | --- | --- |
| `edge_snap` | `false` | Enables edge snapping for moving floating windows. |
| `edge_threshold` | `24` | Edge activation distance in logical pixels. |
| `snap_gap` | `8` | Space around and between half-screen windows, in logical pixels. |
| `bar_color_inactive` | transparent | Inactive titlebar color; transparent falls back to `bar_color`. |
| `workspace_tag` | empty | When set, titlebars and edge snapping apply only to floating windows with this tag. Removing the tag or tiling the window immediately releases titlebar space. |

## Window targeting with `%WINDOW%`

Button `action` commands and `on_double_click` may contain `%WINDOW%`. Every occurrence is replaced synchronously with the clicked titlebar's window address, such as `0x1234abcd`, before the command is spawned. Use it to keep asynchronous actions targeted at the clicked window when focus changes before the command runs:

```lua
hl.plugin.hyprbars.add_button({
  bg_color = "rgb(f7768e)", fg_color = "rgb(1a1b26)", size = 18, icon = "×",
  action = [[hyprctl dispatch 'hl.dsp.window.close({ window = "address:%WINDOW%" })']],
})
```

The replacement contains only `0x` and hexadecimal digits; no window title or other application-controlled text enters the command.

## Edge snapping

Left/right snapping divides the usable monitor area into equal halves, preserving the configured gap and accounting for the titlebar, window borders, monitor scale, and reserved panels. Windows whose minimum size cannot fit a half stay freely placed. The top edge uses Hyprland's native maximized state so decorations remain reachable and normal fullscreen behavior stays available. Dragging a snapped or maximized titlebar restores its floating size under the pointer.

## `omarchy_snap_preview` event

The plugin emits socket2 events only when the snap preview changes:

```text
omarchy_snap_preview>>monitorName,left,x,y,width,height
omarchy_snap_preview>>monitorName,right,x,y,width,height
omarchy_snap_preview>>monitorName,maximize,x,y,width,height
omarchy_snap_preview>>,none,0,0,0,0
```

Geometry is global and logical, including titlebar and borders. Omarchy's shell renders the preview. Leaving an edge, releasing the pointer, closing the dragged window, reloading configuration, or unloading the plugin clears it.

## Hyprland ABI

A Hyprland plugin is only compatible with the exact Hyprland build whose headers it was compiled against, and Hyprland refuses to load a mismatched build. `rebuild_on` in `.omarchy/package.json` rebuilds this package whenever `hyprland` changes. A new Hyprland version also needs the `hyprland=` dependency in `PKGBUILD` moved to it.

Plugin-owned C++ symbols have an `OmarchyFloating` prefix and the library is built with `-fno-gnu-unique`, so it can be unloaded and reloaded cleanly alongside other hyprbars forks such as the Windows XP theme's. Do not use whole-library hidden visibility: Hyprland shares inline state through its headers.

## Layout

The plugin source sits beside `PKGBUILD` as local sources, since makepkg finds those by file name. `tools/verify.py` is a nested-compositor verifier, with `pointer.c` and the wlr virtual pointer protocol it uses to drive real pointer input; it is not part of the build.

## Building

```bash
bin/repo release --package omarchy-hyprland-titlebars
```

Or locally, with the Hyprland headers from the `hyprland` package installed:

```bash
makepkg -f
```

## Verifying

```bash
python3 tools/verify.py src/build/titlebars.so
```

The verifier needs a running Hyprland session with exactly one Hyprland instance, plus `foot`, `grim`, `wayland-scanner`, and a C compiler. It starts a disposable nested Hyprland with its own runtime directory and never loads the candidate library into the parent compositor. It checks repeated load/reload/unload, interleaved with the Windows XP fork when `/usr/lib/omarchy-windows-xp/hyprbars.so` is installed, then exercises real pointer titlebar dragging, both half-screen snaps, top-edge maximize, drag-down restoration, double-click maximize, and preview events. A two-window regression check deliberately delays button and double-click commands and changes focus before they run, to verify that actions keep the clicked window as their target. A final check confirms that `workspace_tag`-scoped titlebars release their space immediately when a window is tiled or untagged.

Screenshots and logs go to `/tmp/omarchy-hyprland-titlebars-verification` by default; pass `--artifacts DIR` to change it.
