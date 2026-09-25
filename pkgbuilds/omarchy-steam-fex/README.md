# Steam launcher for Apple Silicon

`omarchy-steam-fex` provides `omarchy-launch-steam` for the Asahi Linux `steam`, `muvm`, and `FEX-Emu` stack. Those runtime packages come from `asahi-alarm`; `FEX-Emu` provides `FEXBash`. The package is restricted to aarch64 and assumes that stack's `~/.local/share/fex-steam/steam-launcher/bin_steam.sh` layout.

The launcher runs Steam through `muvm` and `FEXBash` with the CEF occlusion workaround. Once Steam's client files are present, it also disables bootstrap verification and repair and patches the Steam UI network initialization block that can leave login waiting indefinitely. Initial bootstrap keeps the normal bootstrap flags. If the FEX launcher is unavailable, it falls back to `steam`.

`omarchy-launch-steam --prepare` creates the current user's desktop override with `Exec=omarchy-launch-steam %U` if it is missing, and applies the same UI patch. Existing overrides and symlinks are preserved on preparation and launch. If an existing override uses a different command, edit its `Exec` entry to use `omarchy-launch-steam %U` when you want this launcher. Each matching chunk is backed up as `.omarchy-bak` before its first patch; existing backups are preserved. The regex matches the original network initialization block, so a patched block is not changed again. An unrelated connected-state assignment elsewhere in the chunk does not suppress the fix. The regex depends on Valve's client code and may need updating when that code changes.

Only the launcher and license are installed. Steam's system desktop entry and downloaded client files remain outside this package's ownership; preparation runs as the desktop user, never in a package installation hook. A downstream Omarchy package that already owns the launcher must release that path before this package is installed, or in the same upgrade transaction.

Runtime dependencies are declared in `package()` so assembling the scripts does not require the Asahi stack in the build container. They remain required dependencies in the resulting package. `check()` runs the offline launcher tests using temporary homes and mocked Steam/muvm commands. To run them directly:

```sh
python pkgbuilds/omarchy-steam-fex/test-launcher.py
```

The launcher was extracted from [omarchy-mx-mac commit 5e8e1188](https://github.com/scottjones/omarchy-mx-mac/commit/5e8e1188e39fae70cf4f7bda1a1d85d66eccae51), credited to Scott Jones, dl-alexandre, and Santeri Hernejärvi. The extraction replaces `omarchy-cmd-present` with `command -v`, removing the dependency on Omarchy itself. Subsequent fixes preserve user desktop overrides and avoid false positives when checking whether the network block needs patching.
