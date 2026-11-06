# Steam launcher for Apple Silicon

`omarchy-steam-fex` provides `omarchy-launch-steam` for the Asahi Linux `steam`, `muvm`, and `FEX-Emu` stack. `FEX-Emu` provides `FEXBash`; the package also requires the x86 root filesystem and both guest Mesa overlays so installation supplies a complete runtime. The accompanying Omarchy `muvm` recipe carries the optional session-bus bridge. The launcher is restricted to aarch64 and assumes the Asahi stack's `~/.local/share/fex-steam/steam-launcher/bin_steam.sh` layout.

The launcher runs Steam through `muvm` and `FEXBash` with the CEF occlusion workaround and `-system-composer`. Once Steam's client files are present, it patches the Steam UI network initialization block that can leave login waiting indefinitely. Initial bootstrap uses Steam's normal checks. Subsequent launches keep update and bootstrap checks enabled but pass `-noverifyfiles`: Steam otherwise detects the modified UI file, replaces it, and loses the login fix. After a client update replaces the UI file, launch again to reapply the patch. If the FEX launcher is unavailable, it falls back to `steam`.

Preparation and translated-client launches enable V8's `--jitless` mode only for
`steamwebhelper`, through FEX's per-application configuration. On the tested M1
Pro this stopped the Steam interface restarting when launching games while
keeping GPU compositing enabled. JavaScript interpretation can be slower and
WebAssembly is unavailable in that helper; game translation is unaffected.
The normal profile path is `~/.config/fex-emu/AppConfig/steamwebhelper.json`.
An absolute `FEX_APP_CONFIG_LOCATION`, the legacy `~/.fex-emu` directory and
`XDG_CONFIG_HOME` are respected; custom config-location variables are passed
through muvm. Existing settings and repeated argument keys are retained, other
V8 flags are preserved, and the original profile is backed up as `.omarchy-bak`
before its first modification. Invalid profiles, user-managed symlinks and an
explicit `--no-jitless` opt-out are preserved with a diagnostic.

The package also installs a PipeWire `node.rules` fragment for the tested
MacBook Pro 14-inch M1 Pro (J314). Both speaker convolver nodes keep processing
between streams, avoiding the observed `Start/EPERM` failure that left games
silent. The existing Asahi DSP graph and speaker protection remain in use.
Keeping the graph active increases idle audio CPU use. The fragment matches
only the two J314 speaker nodes, so microphone and other output policies are
unchanged. Apply it by restarting PipeWire and WirePlumber after installation,
or log out and back in; package installation does not restart live audio.

For the translated client, the launcher passes `GDK_SCALE` and `GDK_DPI_SCALE`
through muvm and sets Steam's desktop UI scale from the focused Hyprland output,
including fractional scales. It falls back to `GDK_SCALE` when monitor information
is unavailable. An explicit `STEAM_FORCE_DESKTOPUI_SCALING` takes precedence.
These values are resolved at launch; restart Steam after changing desktop scale.

When a supported host session bus is reachable, the launcher enables muvm's optional
`--session-bus` bridge so Steam can register its tray icon with the host bar.
This requires a muvm build with session-bus forwarding support and grants the
guest access to the host user's session services. Older builds still launch
Steam and print a diagnostic explaining why its tray icon is unavailable.
The bridge requires an existing absolute `XDG_RUNTIME_DIR` and a single absolute
`unix:path` address. Escaped paths and a `guid` field are supported. When the
address is unset or empty, it checks `$XDG_RUNTIME_DIR/bus`. Unsupported addresses
(including abstract sockets and address lists), missing runtime directories and
unreachable sockets produce a diagnostic and launch Steam without the bridge.
The socket check is nonblocking, so a full listen queue cannot stall the launcher.
Restart an existing VM after upgrading muvm to enable the bridge.

`omarchy-launch-steam --prepare` creates the current user's desktop override with `Exec=omarchy-launch-steam %U` if it is missing, and applies the same UI patch. Existing overrides and symlinks are preserved on preparation and launch. If an existing override uses a different command, edit its `Exec` entry to use `omarchy-launch-steam %U` when you want this launcher. Each matching chunk is backed up as `.omarchy-bak` before its first patch; existing backups are preserved. The regex matches the original network initialization block, so a patched block is not changed again. An unrelated connected-state assignment elsewhere in the chunk does not suppress the fix. The regex depends on Valve's client code and may need updating when that code changes.

The launcher, license and speaker DSP fragment are installed. Steam's system desktop entry and downloaded client files remain outside this package's ownership; preparation runs as the desktop user, never in a package installation hook. A downstream Omarchy package that already owns the launcher must release that path before this package is installed, or in the same upgrade transaction.

Runtime dependencies are declared in `package()` so assembling the scripts does not require the Asahi stack in the build container. They remain required dependencies in the resulting package. `check()` runs the offline launcher tests using temporary homes and mocked Steam/muvm commands. To run them directly:

```sh
python pkgbuilds/omarchy-steam-fex/test-launcher.py
```

The launcher was extracted from [omarchy-mx-mac commit 5e8e1188](https://github.com/scottjones/omarchy-mx-mac/commit/5e8e1188e39fae70cf4f7bda1a1d85d66eccae51), credited to Scott Jones, dl-alexandre, and Santeri Hernejärvi. The extraction replaces `omarchy-cmd-present` with `command -v`, removing the dependency on Omarchy itself. Subsequent fixes preserve user desktop overrides and avoid false positives when checking whether the network block needs patching.
