# Intel T2 Mac packages

Omarchy owns four recipes producing all five required packages. The kernel and
fan daemon compile from source; audio configuration and headers are packaged
data/build files. Apple/Broadcom firmware is packaged proprietary data from an
[Omarchy-owned source fork](https://github.com/omacom/apple-bcm-firmware).
All five install using Arch plus our local outputs, without externally built
arch-mact2 packages. Firmware redistribution rights and hardware qualification
remain unresolved; production installations have not migrated.

All four `.omarchy/package.json` files use `source: local`, an
`upstream_commit` recording the import, and `skip_build: true`. This keeps them
out of scheduled builds while allowing explicit local builds. Normal edge → rc
→ stable promotion remains available after qualification; no fast ring is set.
No production configuration, signing, publishing, or mirror service is changed.

## Inventory and source provenance

Snapshot: September 5, 2026 (America/New_York). The full **37-entry pacman
database**, including dependency and split-base fields, is recorded in
[arch-mact2-inventory.json](arch-mact2-inventory.json), together with its URL and
SHA-256. Directory listings retain old artifacts and are not the current package
set; the database is authoritative for this inventory.

| Required output | Mirror version | Local recipe/source | Build/runtime dependencies |
| --- | --- | --- | --- |
| `linux-t2` | `7.2.3.arch1-1` | `pkgbuilds/linux-t2`, Linux 7.2.3 + Arch patch arch1 + pinned T2 patches | Standard Arch compiler/Rust/BTF tools; runtime `coreutils`, `initramfs`, `kmod` |
| `linux-t2-headers` | `7.2.3.arch1-1` | Same split PKGBUILD and compilation as kernel | Exact local `linux-t2=$pkgver-$pkgrel`; `binutils`, `glibc`, `libelf`, `libgcc`, `openssl`, `pahole`, `xxhash`, `zlib`, `zstd` |
| `apple-t2-audio-config` | `0.4.r21.ga973d53-1` | `deqrocks/t2bce` UCM profiles | `alsa-ucm-conf`; PipeWire/PulseAudio and kernel are optional metadata dependencies |
| `t2fanrd` | `r16.48baf96-1` | `GnomedDev/T2FanRD` Rust daemon | Build: Arch `cargo`, locked crates; runtime `glibc`, `libgcc`, `systemd` |
| `apple-bcm-firmware` | `14.0-1` | `omacom/apple-bcm-firmware`, fork of AdityaGarg8/Apple-Firmware; checked-in Sonoma 14.4.1 Intel blobs | No extra build/runtime dependencies; SHA-256 verified archive and per-file manifest; see [firmware](firmware.md) |

Local revisions use `.1` after the upstream release number, so they sort above
the corresponding mirror builds without an epoch. The exact build results and
resource measurements are in [validation.md](validation.md).

The collection at
[`b92ba80d30afb26f7b7df9dfb5175c47e799b646`](https://github.com/NoaHimesaka1873/arch-mact2-PKGBUILDs/tree/b92ba80d30afb26f7b7df9dfb5175c47e799b646)
declares a **`linux-t2-arch` submodule**. Resolving it with
`git submodule update --init linux-t2-arch` checks out
`b8faf56806b5dc8f0d98e667720c7d02c4175f86`, whose recipe is Linux 6.19.11.
That is stale relative to both the database and Omarchy's current driver setup.
This import instead uses the kernel repository's current `main` commit
[`786d47549c81cefadab58e8a6a7d8ec4065a9467`](https://github.com/NoaHimesaka1873/linux-t2-arch/tree/786d47549c81cefadab58e8a6a7d8ec4065a9467).

Pinned inputs:

* Linux `7.2.3` from `cdn.kernel.org`, SHA-256 and BLAKE2 verified, with Greg
  Kroah-Hartman's detached signature (`647F28654894E3BD457199BE38DBBDC86092693E`).
* Arch `v7.2.3-arch1` patch from `archlinux/linux`, SHA-256 and BLAKE2 verified,
  with heftig's signature (`83BC8889351B5DEBBB68416EB8AC08600F108CDF`). Public
  verification keys are included under `keys/pgp`; no private/signing keys exist
  in these recipes. Signature files use `SKIP` in hash arrays because makepkg
  verifies their signatures against the allowlisted fingerprints.
* T2 patches at
  [`1637df4b0760dc3202c3e6ab4ef7b66a378395bb`](https://github.com/t2linux/linux-t2-patches/tree/1637df4b0760dc3202c3e6ab4ef7b66a378395bb),
  pinned by a full Git commit **and** makepkg's SHA-256/BLAKE2 Git source hashes.
  This contains the `t2bce` stack, Bluetooth, trackpad, Apple SMC and other T2
  changes; individual patches retain their authorship and license notices.
* Audio UCM profiles at
  [`a973d53c8278e9db5ff8314b816d6880309ed39e`](https://github.com/deqrocks/t2bce/tree/a973d53c8278e9db5ff8314b816d6880309ed39e),
  a full-commit GitHub source archive with SHA-256 verification. The package
  retains the original recipe's `GPL-2.0-only` declaration. That source tree has
  no separate UCM license file; no new license grant is inferred here.
* Fan daemon at
  [`48baf962697ec3d4d969c74cf601ee8e15b7aeaa`](https://github.com/GnomedDev/T2FanRD/tree/48baf962697ec3d4d969c74cf601ee8e15b7aeaa),
  a full-commit source archive with SHA-256 verification. `Cargo.lock` is
  retained, `cargo fetch --locked` verifies registry crate checksums, and
  `cargo build --frozen` compiles offline after fetching. `LICENCE` is packaged;
  Cargo declares `GPL-3.0-or-later`.

* Firmware tree at
  [`dc061b535d53e293cdd5793c1255faaca197574b`](https://github.com/omacom/apple-bcm-firmware/tree/dc061b535d53e293cdd5793c1255faaca197574b),
  from a documented macOS runner extraction. The archive and all 132 installed
  Intel files have SHA-256 pins. This is binary/data packaging, not compilation.
  The fork's Actions are disabled, with no package releases. See the firmware
  report for provenance gaps, license findings and local extraction alternatives.

The kernel packaging repository's GPL license and original maintainer and
contributor attribution are retained. The kernel itself declares GPL-2.0-only.
Omarchy's recipe changes are captured in
`linux-t2/.omarchy/patches/0001-omarchy.patch`: omit htmldocs and its dependencies,
keep patches in place for repeat preparation, assert required T2 modules, and
make the header package depend on the exact kernel version. Kernel configuration
is retained intact, with the pinned T2 `extra_config` applied by the recipe.

`tiny-dfr` (currently `v0.3.7.r9.geb711c8-1`) is deliberately out of scope. So are
the old LTS/test/MTP/Xanmod kernels, old fan daemon, DKMS gmux, mirror tools,
installers, Calamares/Jade/Blend/Akshara/welcome packages, old Wi-Fi-only firmware,
and kernel documentation. No build dependency requires any of those packages.

## Local builds and validation

Use an isolated checkout/worktree with empty `build-output/`, `src/` and
`pkgs.omarchy.org/` directories. Do not point `OMARCHY_REPO_ROOT` at a published
tree. The builder resolves dependencies from Arch `core`/`extra`, then our
unsigned `file://` staging repository. The staging repository has priority for
our own outputs; no `[arch-mact2]` entry is needed or allowed for this exercise.

`bin/repo build` can forward to `.repo-host` over SSH (despite some older README
wording). **`bin/build` is local.** `bin/repo build --local` is also local, but
the direct command avoids remote-control and log-rotation side effects.
`push`, `deploy`, `release`, `upload-prebuilt`, signing and repository promotion
are publication commands and must not be used for local validation.

```bash
# Docker or rootless Podman; image comes from the existing build/Dockerfile.
CONTAINER_ENGINE=podman OMARCHY_BUILD_CPUS=8 \
  bin/build --arch x86_64 --package linux-t2 apple-t2-audio-config apple-bcm-firmware t2fanrd

# Use a previously inspected/prepared image and retain local artifacts on retry.
CONTAINER_ENGINE=podman OMARCHY_BUILD_CPUS=8 \
  OMARCHY_SKIP_BUILDER_IMAGE=1 OMARCHY_KEEP_BUILD_WORKSPACE=1 \
  bin/build --arch x86_64 --package linux-t2 apple-t2-audio-config apple-bcm-firmware t2fanrd

CONTAINER_ENGINE=podman bin/validate-t2
build/test-build-reuse.sh
build/test-sync-t2.sh
```

The CPU limit constrains the container and the builder image's `nproc`-derived
make parallelism. The default is unchanged when unset. Keep sufficient disk and
memory available for a full distribution kernel; the initial measurements are
in the validation report.

Reuse checks every declared output's `.PKGINFO` name, architecture and version.
A missing, unreadable or stale header archive triggers the whole kernel split
build. Published DB lookup likewise requires every split output at the same
version. Bump `pkgrel` whenever changing a recipe, configuration or source while
keeping `pkgver`: retained artifacts are version-based caches, not a proof of
bit-for-bit reproducibility or an integrity check of the entire archive payload.

`bin/validate-t2` runs in a fresh container, rejects preinstalled T2 packages and
unexpected repositories, and installs the five outputs through pacman and our
local DB alongside Arch's Broadcom firmware. It checks exact firmware filenames
and hashes, dependency consistency, package files, module metadata,
kernel/header agreement, a test initramfs, an external module compiled against
the installed headers, audio profile paths, and the disabled fan service. It
does not load modules, start fan control, or touch the host's boot setup.

## Updates

These hardware recipes use the existing **local-source + metadata + retained
patches** conventions. They need a coordinated import of source/configuration
and patches, so they do not use a version-only `.omarchy/upstream.sh` hook.
`bin/sync-t2` accepts an explicit reviewed full commit, produces a reviewable diff,
and updates `upstream_commit`. It never commits, builds, uploads or publishes.
There is no new scheduled updater.

```bash
git ls-remote https://github.com/NoaHimesaka1873/linux-t2-arch.git refs/heads/main
# Review the commit's PKGBUILD, configuration, patch pin and signing identities.
bin/sync-t2 linux-t2 FULL_40_CHARACTER_COMMIT --check
bin/sync-t2 linux-t2 FULL_40_CHARACTER_COMMIT

git ls-remote https://github.com/deqrocks/t2bce.git HEAD
bin/sync-t2 apple-t2-audio-config FULL_40_CHARACTER_COMMIT --check
bin/sync-t2 apple-t2-audio-config FULL_40_CHARACTER_COMMIT

git ls-remote https://github.com/GnomedDev/T2FanRD.git HEAD
bin/sync-t2 t2fanrd FULL_40_CHARACTER_COMMIT --check
bin/sync-t2 t2fanrd FULL_40_CHARACTER_COMMIT

# Review/import the desired firmware tree into the Omarchy fork first.
# The version must describe its checked-in files, not its Debian/RPM releases.
bin/sync-t2 apple-bcm-firmware FULL_40_CHARACTER_COMMIT --firmware-version 14.4.1 --check
bin/sync-t2 apple-bcm-firmware FULL_40_CHARACTER_COMMIT --firmware-version 14.4.1
# Same macOS version, changed tree: supply an increasing --pkgrel, e.g. 1.2.
```

Kernel imports preserve the upstream checksums, detached signatures, patch pin
and configuration together, then apply the retained Omarchy patch. Drift that
no longer applies fails before editing. Review any key rotation explicitly;
the importer does not fetch/accept new signing identities automatically.
For audio/fan sources, it calculates the upstream commit count, verifies the
GitHub tar archive's embedded full commit, and hashes the archive and local
service/configuration files. Firmware imports use the explicit reviewed macOS
version, verify the archive's commit and regenerate Intel hashes from Git blobs.
Missing previously supported filenames, empty files and symlinks fail the import;
new Intel filenames appear in the review diff. Removing a board/family requires
an explicit manual coverage/manifest review. The same macOS version needs an
increasing `--pkgrel` when content changes. Update the provenance report with the
new macOS/runner or recovery inputs; the importer cannot prove a version label.
Keep the firmware fork's Actions disabled when importing upstream changes, and
review any inherited workflow changes. No upstream PKGBUILD is executed during import.
Failed downloads, moving refs, wrong archives, downgrades and same-version
content changes fail before edits. Upstream revision changes receive an Omarchy
`.1` suffix. For a local-only change, edit/bump `pkgrel` and the affected hashes
manually, as with other local packages.

After any import, review `git diff`, rebuild, run `bin/validate-t2`, test reuse,
and repeat hardware qualification. The importer is tested with offline Git
fixtures, including an update followed by a no-op, wrong archive, moving-ref and
downgrade failures, plus firmware coverage and same-version release changes.
All four real current pins were also reimported in preview mode without changes. Update success does not establish kernel compatibility.

## Omarchy settings and migration

The default branch was rechecked as `quattro`, at
`959e49dc52a60d35b299d4e13372bc74dd0797ae`. Its
`install/hardware/apple/fix-t2.sh` requests exactly the five packages in the
inventory table. `install/hardware/pacman.sh` currently adds `[arch-mact2]` using
the GitHub mirror release URL with `SigLevel = Never`.

The older `master`, at `f4378f0de5b44d331ee943746a97872b718a6c18`, instead has
`install/config/hardware/apple/fix-t2.sh`. It installs/enables `tiny-dfr`, adds
the user to `video`, loads `apple-bce`, sets the Broadcom Wi-Fi quirk locally,
uses `pcie_ports=compat`, and only writes `Fan1`. `quattro` removes automatic
tiny-dfr installation, uses `t2bce_vhci` and its core/DMA dependencies, loads
`hci_bcm4377`, uses `pm_async=off mem_sleep_default=deep`, and configures both
fans. Its Wi-Fi quirk has moved to the broader Apple hardware handling. Do not
copy the old master settings into a new-kernel migration.

`omarchy-mirror` commit
[`9be083202eef7100ab8ae6ca7e84ec807ce9a420`](https://github.com/omacom/omarchy-mirror/commit/9be083202eef7100ab8ae6ca7e84ec807ce9a420)
introduced the hourly T2 rsync → R2 mirror service, staging the whole Funami
repository. The external GitHub mirror at `a916a8ca9364a1d4014f47bfe9d55c780040f6d5`
also copies Funami binaries (its workflow runs every three hours). Neither is a
source build service. These histories were inspected read-only.

Retiring the external dependency needs a later coordinated change:

1. Resolve the firmware release requirement: establish rights for the pinned
   Omarchy-owned blob tree, or implement installation-time/on-device extraction
   with suitable licensing and offline-install support. Local dependency closure
   now works; fork ownership does not itself grant redistribution rights.
2. Qualify all five local packages on representative T2 hardware, including the
   kernel and audio pair. Keep a bootable fallback kernel and recovery method.
3. Enable scheduled builds deliberately; build for each intended channel's
   Arch snapshot and sign/publish through the normal repository workflow.
4. Update Omarchy's installer, upgrades and ISO/offline paths to consume these
   signed Omarchy packages. Remove `[arch-mact2]` and legacy T2 URLs from both new
   installations and existing machines only after closure is available in their
   channel. Check `vercmp` against whatever external versions exist at migration
   time; a newer external release could outrun this branch's pins.
5. Deal explicitly with optional `tiny-dfr` and old extra packages installed by
   older releases; the focused set does not maintain those packages for users.
6. After all consumers are migrated, separately retire the old T2 mirror timer,
   service and hosting. No such production action is part of this branch.

Compilation and container validation do not establish hardware readiness.
Outstanding checks: UEFI/Limine boot and encrypted-root keyboard input;
keyboard, trackpad and optional Touch Bar behavior; Wi-Fi across models/bands
and Bluetooth with device-specific firmware; speakers, microphones and headset
switching at safe volume; both fans, thermal response and restoration to
automatic control on daemon exit; repeated suspend/resume, NVMe, networking,
audio and fan behavior after resume; shutdown and battery/power behavior.
