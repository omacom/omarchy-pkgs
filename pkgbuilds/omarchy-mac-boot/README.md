# omarchy-mac-boot

Apple Silicon boot support for Omarchy: the Mac mkinitcpio drop-ins and initcpio hooks, in-place LUKS conversion in the initramfs, vendor firmware in early boot, first boot of a Mac image, the Limine activation gate and the boot check. The source is `packages/omarchy-mac/boot/` in omacom/omarchy-mac, with its own tests. The recipe pins an exact omarchy-mac commit, copies that directory away from the surrounding desktop tree in `prepare()` and stages the package from the copy with its `install` script. `check()` runs its `test/all` in the full checkout instead, because some tests compare the payload with the desktop source around it (omacom/omarchy-mac#582 and #598). The recipe itself holds only metadata, `backup=` and the pacman scriptlet.

It follows the fork recipe in maralcbr/omarchy-pkgs (`asahi-quattro`, `pkgbuilds/omarchy-mac-boot` at 20260921-10), which carried the payload as files in the recipe.

## Scope

The package is aarch64-only and published to edge only. It widens to rc and stable only after M1 and M2 cold-boot qualification. It carries the Apple platform tag, `groups=('omarchy-platform-apple-silicon')`, which omarchy-settings' pacman platform guard uses to keep it off other machines once that guard ships (omacom/omarchy-mac#539, `docs/platform-guard.md`). Its only provides are the retired Apple-only names, and nothing generic depends on it or on them, so nothing generic can pull it onto non-Apple aarch64 machines. Its one Apple-only dependency, `asahi-scripts`, comes from the asahi-alarm repository that only the Apple profile configures.

It requires `limine-mkinitcpio-hook` 1.39.0-2 or newer: that is the first build whose hooks leave a Mac's `/boot` to mkinitcpio until Limine is activated. With an older hook, Limine's kernel hook replaces mkinitcpio's by name, and this package's `limine-ready` gate stops it on a Mac that still boots GRUB, so a kernel update would never reach `/boot`.

## HOOKS baseline

From the source that drops the boot package's own Plymouth fragment (omacom/omarchy-mac#544), the Apple drop-ins build on omarchy-settings' HOOKS baseline, `/etc/mkinitcpio.conf.d/00-omarchy-hooks.conf` (omacom/omarchy-mac#536). With an older settings package the Mac initramfs loses Plymouth at the passphrase prompt. A settings version cannot express this: quattro candidate builds sort below stock releases, and `omarchy` pins its settings version exactly. So when the staged payload has no `93-omarchy-mac-plymouth.conf`, `package()` adds a dependency on the name `omarchy-mkinitcpio-hooks-baseline`. Every settings package that ships the baseline on aarch64 (`omarchy-settings`, `omarchy-settings-dev`, candidate builds) must `provide` that name. Until one does, such a build of this package cannot be installed: it fails outright rather than silently booting without Plymouth.

## Publish order

A new pin publishes on merge, so check what the pinned source needs first:

- **Settings baseline.** A pin that includes omacom/omarchy-mac#544 (no `93-omarchy-mac-plymouth.conf`) needs omarchy-settings with the HOOKS baseline (omacom/omarchy-mac#542) published on aarch64, and providing `omarchy-mkinitcpio-hooks-baseline`. Publish that first; otherwise this build cannot be installed.
- **Update verification.** A pin that includes omacom/omarchy-mac#543 (`/usr/lib/omarchy/mac-boot/update-verify`) must publish before any runtime that carries #543. Otherwise that runtime blocks every update on Macs whose `omarchy-mac-boot` predates it.
- **Reset and key-slot entrypoints.** A pin that includes omacom/omarchy-mac#552 (`reset-prepare`, `reset-verify`, `reset-commit`, `reset-rollback`) and #553 (`luks-slots`) must publish before any runtime that carries them. That runtime's `omarchy-lifecycle-dispatch` requires them on Apple Silicon, so otherwise factory reset, owner setup and `omarchy-drive-password` on the system disk fail on Macs whose `omarchy-mac-boot` predates them.
- **Reset first-boot markers.** A pin that includes omacom/omarchy-mac#579 (`reset-prepare` clears the factory root's first-boot state and arms `mac-first-boot/pending`) must publish before any runtime that carries #579's `omarchy-system-factory-reset`, which no longer does that inline. Otherwise a factory reset on a Mac whose `omarchy-mac-boot` predates it leaves the factory root without the Mac's first boot, and so without its package keyring, or with an older image's conversion token. A newer boot package with an older runtime is safe: the steps are idempotent.
- **Speaker safety owner.** A pin that includes omacom/omarchy-mac#567 no longer presets or enables `speakersafetyd`; `omarchy-mac` owns it from omacom/omarchy-mac#535. Re-pin `omarchy-mac` at or past #535 in the same merge as that pin, or publish it first. Edge `omarchy-mac` 0.1.0-5 (b4a79d83d) predates #535 and ships no preset for it, so with only the boot package re-pinned a `systemctl preset-all` on an edge Mac disables the speaker amps' safety daemon, and an image built from edge fails its image check.

## Transition

- It provides, conflicts with and replaces `omarchy-apple-boot` and `omarchy-first-boot`. The scriptlet moves a pending `omarchy-first-boot` marker to `omarchy-mac-first-boot`, drops the replaced unit's dangling enable link and points at a customised `90-omarchy-asahi.conf.pacsave`.
- `pkgver` is the UTC commit date of the pin, so any pin from `20260925` on upgrades the fork's `20260921-10` on mx-mac Macs. The files the fork shipped that the source no longer does (the image finalize tools, the upstream ARM repository key and the GRUB snapshot-menu hook) are removed by that upgrade.
- `backup=` covers every `/etc` file and `/usr/lib/omarchy/initcpio`. It includes `/etc/default/update-m1n1`, which pins update-m1n1's device-tree order to the C locale. On a Mac that already has its own unowned copy, pacman keeps it and installs the shipped one as `.pacnew`. The snapshot restore hooks in `/etc/boot/hooks` are symlinks to `/usr/bin/omarchy-mac-snapshot-check`, not files, so they stay out of it.

## Updates

Updates are reviewed pins, never a branch:

1. Set `_commit` to the full omarchy-mac SHA and `pkgver` to its UTC commit date (`TZ=UTC0 git show -s --format=%cd --date=format-local:%Y%m%d <sha>`); `prepare()` checks both.
2. Reset `pkgrel` to 1 when `pkgver` changes; bump it for a second pin on the same date or a rebuild.
3. Refresh `sha256sums` with `makepkg -g`.
4. Check the pin against [Publish order](#publish-order). Before the first pin that includes omacom/omarchy-mac#567 publishes, `omarchy-mac` must be published at or past #535, or re-pinned in the same pull request.
