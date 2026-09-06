# VibeCAD Preview on Omarchy

`vibecad-preview-bin` tracks published RC releases marked prerelease on GitHub. `vibecad-bin` is reserved for stable releases (not marked prerelease and with no prerelease suffix). As of 2026-09-04 upstream has published only RCs, so no stable binary package is included. Do not reclassify an RC as stable.

An inactive stable recipe is kept in `../vibecad-bin/PKGBUILD.in`. When upstream publishes a stable release, activate that stub with its real version and verified checksums. Keep the launcher and update hook identical. The hook selects stable or preview based on `pkgname`. Both variants provide and conflict with `vibecad`, so switching variants replaces the installed package and retains user documents and preferences. Neither variant is installed as a dependency of the other.

Launch VibeCAD from the application menu or run `vibecad`. The launcher reads the focused Hyprland monitor's scale because the upstream AppImage forces Qt's XCB backend. Fonts and icons retain their upstream defaults and scale together. No font preferences, theme files, window modes, or global display settings are changed by the package.

Scaling is selected at startup. Restart VibeCAD after moving to a differently scaled monitor. Explicit Qt scaling environment variables take precedence. Outside a reachable Hyprland session, the launcher leaves Qt's scaling unchanged.

Updates are managed by pacman; the supported VibeCAD update policy disables its in-app updater. On AMD hardware the launcher also preloads the host's `libdrm_amdgpu` to avoid a conflict with the bundled library.

Once accepted and published by Omarchy, the existing six-hourly upstream-sync workflow proposes version/checksum updates. The package uses the standard 24-hour release quarantine and fast ring. After an update is reviewed, merged, built, and published, normal Omarchy updates or `sudo pacman -Syu` upgrade the installed variant. A locally installed package receives no new upstream builds until that repository publication exists. This package does not add an unattended updater or switch release tracks automatically. The Omarchy edge/rc/stable repository channels are separate from upstream VibeCAD's stable/preview classification: the explicit Preview package is opt-in on any supported channel.

For installations that used the earlier Isengard experiments, user launchers and desktop overrides can shadow the packaged launcher. Retire those overrides after installing this package revision. The package deliberately does not modify files in users' home directories.
