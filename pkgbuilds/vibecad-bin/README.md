# VibeCAD stable package stub

Inactive until upstream publishes a stable Linux release. `PKGBUILD.in` and `.omarchy/package.json.in` are templates, not registered package inputs; Omarchy's build and sync discovery skip this directory without `PKGBUILD`.

The launcher contains the same automatic Hyprland/Qt scaling and AMD DRM fixes as `vibecad-preview-bin`. Keep `vibecad`, `update-policy.json`, and `.omarchy/upstream.sh` byte-identical between variants. The update hook selects stable releases for `pkgname=vibecad-bin` and rejects RC tags even if GitHub incorrectly labels them stable.

To activate after a stable release exists:

1. Verify the official GitHub release is not a draft or prerelease and has a version tag without an alpha, beta, or RC suffix.
2. Fill `@STABLE_PKGVER@` (for example, `26.3.1.build1`) and the three stable source checksum placeholders with the actual release metadata. Verify all local-source checksums too.
3. Rename `PKGBUILD.in` to `PKGBUILD` and `.omarchy/package.json.in` to `.omarchy/package.json`.
4. Confirm the launcher, policy, and update hook still match Preview. Build, test, and review the package before enabling its Omarchy menu entry.

Do not substitute an RC for a missing stable release. Once published, this package follows normal Omarchy/pacman updates. It conflicts with the Preview variant through their shared `vibecad` provide; neither track silently switches to the other.
