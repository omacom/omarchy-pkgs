# omarchy-mac

Apple Silicon runtime support for Omarchy: Wi-Fi resume recovery, the headset microphone mapping, the notch modprobe default and the NetworkManager Wi-Fi backend. The source is `packages/omarchy-mac/` in omacom/omarchy-mac, with its own version and tests. The recipe pins an exact `quattro-upstream` commit and packages only that directory; `prepare()` copies it away from the surrounding desktop tree before `check()` runs its tests.

Ported from Scott Jones's recipe in omarchy-mac/omarchy-pkgs-aarch64 (`pkgbuilds/omarchy-mac` at `02ed7b250f7edcf7c5f748acaf7b21ef0a764e9d`). It supersedes the unpublished `omarchy-settings-asahi` recipe.

## Scope

The package is aarch64-only and published to edge only. It widens to rc and stable only after M1 and M2 cold-boot qualification. It depends on the generic `omarchy` package. Its only `provides` is `omarchy-platform`, paired with `conflicts=('omarchy-platform')`: it owns `/usr/share/omarchy-platform`, the platform root Omarchy reads, so only one platform package can be installed. Nothing may depend on `omarchy-platform`, or a dependency could pull this package onto non-Apple aarch64 machines. It ships no kernel, boot, installer or trust configuration; those belong to `omarchy-mac-boot`.

Installing the package enables no services, but its vendor configuration applies on the next service start or module load: the iwd Wi-Fi backend for NetworkManager, the `appledrm` notch option and the WirePlumber headset microphone policy. `omarchy-mac-setup-system` and `omarchy-mac-setup-user` enable the Wi-Fi resume and microphone units, and they exit unless `omarchy-hw-apple-silicon` reports Apple Silicon. Stock Omarchy does not yet ship that detector or call these entrypoints, so on a stock install the units stay disabled until the platform detector and profile work lands.

Runtime dependencies are declared in `package()`, so the builder stages and tests the add-on without installing the desktop.

## Ownership move (from omacom/omarchy-mac#631)

From this pin the package ships its setup entrypoints in `/usr/lib/omarchy/mac`, the Apple pacman templates in `/usr/share/omarchy-mac/pacman` and the three-finger workspace swipe in `/usr/share/omarchy/default/hypr/platform`, and owns `/usr/bin/omarchy-hw-apple` and `/usr/share/omarchy/bin/omarchy-hw-apple`, which a quattro-upstream runtime built before that commit shipped. The runtime and this package must upgrade in one transaction, from the same candidate set; installing only this package over an older quattro runtime stops on the file conflict, and upgrading only the runtime drops the alias.

## Platform root (from omacom/omarchy-mac#660)

From this pin (`49c01e2dd`, 0.1.0-8) the package ships the Mac's desktop files in `/usr/share/omarchy-platform` (Hyprland defaults, settings and gestures, key names, notch cutouts and `displays.conf`), which the runtime from omacom/omarchy#13362 reads at that fixed path, and keeps identical copies at the old `/usr/share/omarchy/default/.../platform` paths for a runtime that does not read the root yet. Publish it with or before that runtime: the runtime with an older omarchy-mac loses the Mac's binds, key names, notch cutouts and backlight choice.

## Updates

Updates are reviewed pins, never a branch. To release a change to the add-on:

1. Set `_commit` to the full `quattro-upstream` SHA and `pkgver` to `packages/omarchy-mac/version` at that commit.
2. Reset `pkgrel` to 1 when `pkgver` increases; bump it to re-pin or rebuild the same version.
3. Refresh `sha256sums` with `makepkg -g`.

Desktop-only commits on `quattro-upstream` do not need a new pin. `0.1.0-5` sorts above the `0.1.0-4.<run>` candidates the collaboration builder produced for test images.
