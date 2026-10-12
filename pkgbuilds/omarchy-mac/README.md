# omarchy-mac

Apple Silicon runtime support for Omarchy: the platform root (key names, notch cutouts, display and audio hints, keyrings), Wi-Fi resume recovery and the iwd backend, the headset microphone mapping, speaker safety, the audio watchdog, setup and app hooks, battery charge limits and the hardware video decode default. The source is `omarchy-mac/` in [omacom/omarchy-mac-pkgs](https://github.com/omacom/omarchy-mac-pkgs), with its own version and tests. The recipe pins an exact `main` commit and packages only that directory; `prepare()` copies it away from the rest of the checkout before `check()` runs its tests.

Ported from Scott Jones's recipe in omarchy-mac/omarchy-pkgs-aarch64 (`pkgbuilds/omarchy-mac` at `02ed7b250f7edcf7c5f748acaf7b21ef0a764e9d`). It supersedes the unpublished `omarchy-settings-asahi` recipe. Up to 0.1.0-6 it built from `packages/omarchy-mac/` in omacom/omarchy-mac.

## Scope

The package is aarch64-only and published to edge only. It widens to rc and stable only after M1 and M2 cold-boot qualification. It depends on the generic `omarchy` package. Its only `provides` is `omarchy-platform`, paired with `conflicts=('omarchy-platform')`: it owns `/usr/share/omarchy-platform`, the platform root Omarchy reads, so only one platform package can be installed. Nothing may depend on `omarchy-platform`, or a dependency could pull this package onto non-Apple aarch64 machines. It ships no kernel, boot, installer or trust configuration; those belong to `omarchy-mac-boot`.

Installing the package enables no system services, but its vendor configuration applies on the next service start or module load: the iwd Wi-Fi backend for NetworkManager, the `appledrm` notch option and the WirePlumber headset microphone policy. The audio watchdog user unit is enabled by a vendor link and starts with the next graphical session; its `ExecCondition` skips it where `omarchy-hw-apple-silicon` is missing or says no. Omarchy runs the system and user setup through `omarchy-lifecycle-dispatch` (`/usr/lib/omarchy/mac`); a runtime without the dispatcher leaves them to `omarchy-mac-setup-system` and `omarchy-mac-setup-user`.

`depends` carries what every Mac needs, so an offline first boot has it and an owner can't remove it: the speaker stack with `speakersafetyd` named (its unit is this package's preset), `alsa-ucm-conf-asahi`, `rtkit`, `pipewire-alsa`, `pipewire-pulse`, `vulkan-asahi` and `asahi-alarm-keyring` (the keyring of the `[asahi-alarm]` repository, named in the platform root's `keyrings`). avd-fw, libva-v4l2_request-avd, wf-recorder and widevine stay out: they are removable defaults in the runtime's Apple package list. Runtime dependencies are declared in `package()`, so the builder stages and tests the add-on without installing the desktop.

## What 0.1.0-11 and later drop

From omacom/omarchy-mac-pkgs the package no longer ships the fork's `legacy/` copies (`/usr/share/omarchy-mac/legacy`) or the setup that retired them; pacman removes them on upgrade. The Apple pacman templates, the `omarchy-hw-apple` alias, the copies under `/usr/share/omarchy` and the platform Hyprland files that lab candidates 0.1.0-7 to 0.1.0-10 carried are gone too: Omarchy from omacom/omarchy#13362 owns the templates and the detector, and the Hyprland defaults wait for a core slot. Converting a fork or mx-mac Mac is a separate migration script, not this package.

## Publish order

- **Runtime.** Publish with or before the runtime from omacom/omarchy#13362, which reads `/usr/share/omarchy-platform` and dispatches setup to `/usr/lib/omarchy/mac`. That runtime with an older omarchy-mac loses the Mac's key names, notch cutouts and keyring refresh, and keeps Omarchy's generic setup.
- **Boot package.** `omarchy-mac-boot` no longer presets `speakersafetyd`; this package does, from omacom/omarchy-mac#535. Every pin from omacom/omarchy-mac-pkgs includes it, so publish this pin with or before the matching `omarchy-mac-boot` pin.

## Updates

Updates are reviewed pins, never a branch. To release a change to the add-on:

1. Set `_commit` to the full omacom/omarchy-mac-pkgs `main` SHA and `pkgver` to `omarchy-mac/version` at that commit.
2. Reset `pkgrel` to 1 when `pkgver` increases; bump it to re-pin or rebuild the same version.
3. Refresh `sha256sums` with `makepkg -g`.

Commits that touch only `omarchy-mac-boot/`, the manual or the tools do not need a new pin. `0.1.0-12` sorts above edge's `0.1.0-6`, the first draft of this pin (`0.1.0-11`) and every lab candidate up to `0.1.0-10`.
