# omarchy-mac-boot

Apple Silicon boot support for Omarchy: the Mac mkinitcpio drop-ins and initcpio hooks, in-place LUKS conversion in the initramfs, vendor firmware in early boot, first boot of a Mac image, the Limine activation gate and the boot check. The source is `packages/omarchy-mac/boot/` in omacom/omarchy-mac, with its own tests. The recipe pins an exact omarchy-mac commit, copies that directory away from the surrounding desktop tree in `prepare()`, runs its `test/all` in `check()` and stages the package with its `install` script. The recipe itself holds only metadata, `backup=` and the pacman scriptlet.

It follows the fork recipe in maralcbr/omarchy-pkgs (`asahi-quattro`, `pkgbuilds/omarchy-mac-boot` at 20260921-10), which carried the payload as files in the recipe.

## Scope

The package is aarch64-only and published to edge only. It widens to rc and stable only after M1 and M2 cold-boot qualification. It carries the Apple platform tag, `groups=('omarchy-platform-apple-silicon')`, so omarchy-settings' pacman platform guard keeps it off other machines (omacom/omarchy-mac `docs/platform-guard.md`). Its only provides are the retired Apple-only names, and nothing generic depends on it or on them, so nothing generic can pull it onto non-Apple aarch64 machines. Its one Apple-only dependency, `asahi-scripts`, comes from the asahi-alarm repository that only the Apple profile configures.

It requires `limine-mkinitcpio-hook` 1.39.0-2 or newer: that is the first build whose hooks leave a Mac's `/boot` to mkinitcpio until Limine is activated. With an older hook, Limine's kernel hook replaces mkinitcpio's by name, and this package's `limine-ready` gate stops it on a Mac that still boots GRUB, so a kernel update would never reach `/boot`.

## HOOKS baseline

From the source that drops the boot package's own Plymouth fragment (omacom/omarchy-mac#544), the Apple drop-ins build on omarchy-settings' HOOKS baseline, `/etc/mkinitcpio.conf.d/00-omarchy-hooks.conf` (omacom/omarchy-mac#536). With an older settings package the Mac initramfs loses Plymouth at the passphrase prompt. A settings version cannot express this: quattro candidate builds sort below stock releases, and `omarchy` pins its settings version exactly. So when the staged payload has no `93-omarchy-mac-plymouth.conf`, `package()` adds a dependency on the name `omarchy-mkinitcpio-hooks-baseline`. Every settings package that ships the baseline on aarch64 (`omarchy-settings`, `omarchy-settings-dev`, candidate builds) must `provide` that name. Until one does, such a build of this package cannot be installed: it fails outright rather than silently booting without Plymouth.

## Transition

- It provides, conflicts with and replaces `omarchy-apple-boot` and `omarchy-first-boot`. The scriptlet moves a pending `omarchy-first-boot` marker to `omarchy-mac-first-boot`, drops the replaced unit's dangling enable link and points at a customised `90-omarchy-asahi.conf.pacsave`.
- `pkgver` is the UTC commit date of the pin, so `20260925-1` upgrades the fork's `20260921-10` on mx-mac Macs. The files the fork shipped that the source no longer does (the image finalize tools, the upstream ARM repository key and the GRUB snapshot-menu hook) are removed by that upgrade.
- `backup=` covers every `/etc` path and `/usr/lib/omarchy/initcpio`. It includes `/etc/default/update-m1n1`, which pins update-m1n1's device-tree order to the C locale. On a Mac that already has its own unowned copy, pacman keeps it and installs the shipped one as `.pacnew`.

## Updates

Updates are reviewed pins, never a branch:

1. Set `_commit` to the full omarchy-mac SHA and `pkgver` to its UTC commit date (`TZ=UTC0 git show -s --format=%cd --date=format-local:%Y%m%d <sha>`); `prepare()` checks both.
2. Reset `pkgrel` to 1 when `pkgver` changes; bump it for a second pin on the same date or a rebuild.
3. Refresh `sha256sums` with `makepkg -g`.
