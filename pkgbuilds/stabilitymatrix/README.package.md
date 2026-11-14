# Stability Matrix on Omarchy

Packages the official Linux x86_64 release of [Stability Matrix](https://github.com/LykosAI/StabilityMatrix).
The executable is extracted unchanged from the upstream AppImage, so FUSE and
a separate .NET runtime are not needed. Desktop use requires X11/XWayland.

## Build and install

From an omarchy-pkgs checkout with a working container engine:

```bash
bin/repo build --local --mirror edge --arch x86_64 --package stabilitymatrix
sudo pacman -U build-output/edge/x86_64/stabilitymatrix-2.16.4-1-x86_64.pkg.tar.zst
stabilitymatrix
```

Once published to your configured Omarchy channel, use `omarchy pkg add stabilitymatrix`.
Run the application as your normal desktop user. This is community packaging,
not an official Lykos AI build modification or endorsement.

## Data and updates

The launcher honours an existing `LibraryPath` in
`${XDG_CONFIG_HOME:-~/.config}/StabilityMatrix/library.json`. Missing drives or
invalid configuration stop launch rather than silently selecting a new library.
It also recognises an existing `~/StabilityMatrix/settings.json` installation.
Fresh installations use `${XDG_DATA_HOME:-~/.local/share}/StabilityMatrix`.
Relative XDG paths are ignored, as required by the XDG specification.

To select another library explicitly:

```bash
stabilitymatrix --data-dir /absolute/path/to/your/library
```

An existing `--home-dir` argument changes where the launcher reads `library.json`.
Changing the library through the app takes effect on the next launch; leave
Portable Mode unchecked. Old AUR portable data under `/opt/stabilitymatrix/Data`
is not moved or adopted automatically: back it up and select a user-owned copy
before switching packages.

Pacman owns the application and updates it through normal Omarchy updates.
Upstream currently has no supported distribution-level self-update disable switch: notifications
may still appear, and the in-app application updater cannot write to `/usr/bin`
as a normal user. Do not run it with sudo to work around that restriction.
The application may generate a per-user desktop entry with the same desktop ID;
it calls the package launcher so the data handling is preserved.

Stability Matrix still installs and updates its managed tools (such as ComfyUI),
Python environments and models in the library. GPU drivers and the appropriate
compute backend must be configured for your hardware. No models or GPU drivers
are bundled or automatically installed by this Arch package.

## Removal and rollback

```bash
sudo pacman -R stabilitymatrix
```

The package has no removal hook: models, outputs, environments and settings stay
in user storage. A self-generated launcher can remain at
`~/.local/share/applications/stabilitymatrix-app.desktop`; remove that user file
manually if it remains after uninstall. To roll back, use `sudo pacman -U` with
your saved older package file. Back up the library before application upgrades;
rolling back an executable does not roll back its data format.

## Provenance and validation

The official binary is governed by the [Lykos EULA](https://lykos.ai/license),
included as `EULA.md` from the site's published Markdown on 2026-09-30.
The AppImage's bundled AGPL text is also installed. Application bytes, icon and
notices are retained; there are no binary patches, stripping or branding changes.
The existing AUR recipe at `742c9d08c918b8ca275aa8f178857ed7407674fb` was inspected;
this recipe is maintained locally and follows GitHub release asset digests.
It uses the normal edge → rc → stable policy, without a fast-ring override.

`check()` validates the desktop file and exercises the launcher's path selection,
argument forwarding and failure handling. A successful package build does not
establish GPU compatibility. Live Omarchy install/upgrade/removal, first-run GUI
and actual image generation still require desktop acceptance testing.
