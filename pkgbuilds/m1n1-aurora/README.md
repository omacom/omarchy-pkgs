# m1n1-aurora

Build the canonical Aurora bootloader package from an immutable omacom/m1n1
commit. The current candidate is bc79acc434e612ffcb95bfc7cb2fd7543afac5f2
(merged source PRs #6, #7, #8, #10, #12, #13, #14, #15, #17, #18 and #19: on
the 16-inch M3 Max with the 40-core GPU, J516C, m1n1 requests its existing display and GPU
handoffs by default, subject to the existing checks), with Clang/lld, Rust 1.89.0 and
`-Os`. Native J516C graphics also need the kernel's automatic J516C display request and
display-before-GPU gate (omacom/linux-aurora#246) and the kernel's J516C board data; those
are outside this package. The merge also includes #17's T6030 external-display
dependency fix: a display handoff requests its required memory handoff. The
package's existing 48/128/256 artwork is unchanged. The former USB4
alias patch is already in the source; the APFS preboot UUID handoff proposed in
omarchy-pkgs #1485 is also present upstream, so neither needs a local patch.

## Existing installations

The package replaces the downstream `aura` and `m1n1-neo` packages and conflicts
with the stock `m1n1`; it never automatically replaces the stock package.
It provides `m1n1` at its own `pkgver` for the kernel dependency. An installed
`m1n1-aurora` upgrades normally; an `aura` installation accepts pacman's named
replacement transaction. `aura` is removed in the same transaction, leaving
exactly one provider for the boot checker merged in omarchy-mac-pkgs #52.

The runtime U-Boot dependency is the virtual `uboot-asahi`. A legacy install
keeps the stock `uboot-asahi`; an `aura` install keeps `uboot-aurora`, which
provides it. Depending on `uboot-aurora` by name would make every legacy
upgrade hit its conflict with `uboot-asahi`, which `--noconfirm` refuses, and
then ask the user to swap U-Boot. Images select `uboot-aurora` explicitly.

Stage 2 remains `/usr/lib/asahi-boot/m1n1.bin`. The existing asahi-scripts hook
rebuilds `m1n1/boot.bin` on the selected system ESP from the loader, kernel DTBs
and U-Boot. This package adds no install script, Recovery command or ESP rename.
`/etc/default/update-m1n1` overrides are left alone.

Stage 1 raw/Mach-O artifacts are available under
`/usr/share/m1n1-aurora/stage1/`. The old `/usr/share/aura/stage1/aura-raw.bin`
and `aura.macho` paths remain regular-file copies for installer compatibility.
Normal package updates never enroll Stage 1; that requires a separate explicit
installer or Recovery operation. Large Neo images need matched Stage 1 and
Stage 2 support, so a Stage 2 package upgrade alone is not a Stage 1 migration.

## Coordinated image rollout

Before merging this package migration, land the image builder change that
switches package selection and signed candidate-set ownership from `aura`
to `m1n1-aurora`. Its existing
`m1n1-aurora -> aura` rewrite must be removed, and its artifact/ownership checks
must expect `m1n1-aurora`. The compatibility files preserve artifact lookups;
they do not change that exact package-name selection. Keep accepting already
installed `aura` in the boot checker. Leave the legacy `aura` recipe unchanged
until that coordinated rollout; do not select both providers in an image.
Otherwise a fresh image still installs `aura` and immediately replaces it at
its first `pacman -Syu` (`--noconfirm` accepts the default-yes replacement).
This source and provider change also requires explicit maintainer approval.

## Qualification

The #19 merge pin includes #17; this exact combined package has not yet been
natively built or booted. The earlier #19 package was cold-booted by its J516C
owner, and #17 was separately boot-tested on an M3 Pro. Those results do not
replace qualification of this merge pin.

Edge is the qualification channel. `package()` uses `--build-only`, so merging
this PR allows the normal build/publish workflow to publish an edge candidate;
the JSON record does not automatically block that workflow. The package is
not qualified for rc/stable promotion: `hardware_tested` remains false.
Full-mode validation is a manual prerequisite before rc/stable promotion,
not a CI gate wired into the promotion workflow.

Required hardware matrix (all rows still pending for this exact package):

| Stage 1 retained/enrolled | Stage 2 | Cold-boot systems |
| --- | --- | --- |
| Existing aurora-silicon/Asahi Stage 1 from a `m1n1-aurora` install | This omacom package | M1 and M2 |
| Existing Aura Stage 1, including `BUILTIN_LOGO=aurora` | This omacom package | M1, M2 and M3 |
| Existing Aura J700 Stage 1 (`esp/aurora/stage1-j700.bin`) | This omacom package | Neo/J700 |
| This omacom package, explicitly enrolled | This omacom package | Neo/J700 |

The first three rows exercise the ordinary update path: install only the
package, let the existing `update-m1n1` hook compose Stage 2 with the installed
DTBs and U-Boot, and leave Stage 1 unchanged. Record exact Stage 1 identity,
the installed U-Boot provider and version (`uboot-asahi` on legacy installs,
`uboot-aurora` on Aura ones), package and composed-image hashes, cold boot to
the desktop, CPU count, internal/external displays, and rollback evidence. No
matched-pair-only test substitutes for an upgrade row. In full mode
`validate-qualification.py` requires native build, matched boot, repair and
upgrade evidence plus a cold-boot report for each upgrade pair: legacy M1 and
M2, and Aura M1, M2, M3 and Neo.

### Restoring the previous Stage 2

`update-m1n1` copies the old image to `m1n1/boot.bin.old` on the system ESP
whenever it changes `m1n1/boot.bin`, but the next change (a kernel or U-Boot
update) overwrites that copy. Before each qualification upgrade, also copy
`m1n1/boot.bin` somewhere off the ESP. If the Mac no longer boots Omarchy,
boot macOS or macOS Recovery, find the Omarchy EFI partition with
`diskutil list`, mount it with `diskutil mount <identifier>`, and copy the
saved image (or `m1n1/boot.bin.old`) back over `m1n1/boot.bin`. Then boot
Omarchy and downgrade the package, so the next hook run composes the old
Stage 2 instead of putting the new one back.

The source pin includes the GNU ld orphan-layout fix and linker regression
tests merged in omacom/m1n1 #13; this recipe explicitly uses lld. No Stage 1
enrollment, target installation or hardware boot is performed by updating
this package PR.
