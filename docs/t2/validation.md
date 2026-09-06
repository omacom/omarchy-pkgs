# Local validation results — September 5, 2026

Four unsigned packages were built locally and installed successfully in a fresh
x86_64 container. **Firmware independence and actual T2 hardware readiness are
not established.** The full five-package transaction fails specifically with
`error: target not found: apple-bcm-firmware` when only Arch and our outputs are
available. [Firmware provenance and the remaining decision](firmware.md).

| Output | Version | Compressed bytes | Result |
| --- | --- | ---: | --- |
| linux-t2 | 7.2.3.arch1-1.1 | 156,338,541 | Compiled and packaged |
| linux-t2-headers | 7.2.3.arch1-1.1 | 91,112,464 | Same compilation; external module build passed |
| apple-t2-audio-config | 0.4.r21.ga973d53-1.1 | 4,390 | UCM data packaged from pinned source |
| t2fanrd | r16.48baf96-1.1 | 270,180 | Compiled with locked/frozen Cargo dependencies |

Kernel release: **`7.2.3-arch1-Watanare-T2-1.1-t2`**. All SHA-256 hashes and
parsed `.PKGINFO` records are in [built-packages.json](built-packages.json).
The exact archives remain in `build-output/edge/x86_64/` of this worktree;
they were not signed or published. Reuse and validation left their hashes
unchanged. There is no `linux-t2-docs`, automatic debug package, old driver DKMS
package, `tiny-dfr`, or placeholder firmware package among the outputs.

## Environment and resources

Worktree: `/home/ryan/Work/omarchy/omarchy-pkgs/.worktrees/t2-package-builds`,
branch `feat/t2-package-builds`, based on `b81d678`. The original checkout was
left on its original `master`, with the existing untracked `pkgbuilds/strata/`
unchanged. Sources and the inspected external firmware archive are outside this
worktree in `../t2-sources/`; that directory was never mounted into a builder.

Host: AMD Ryzen 9 9950X3D, 32 logical CPUs, 91 GiB RAM, x86_64. Approximately
913 GiB disk was available at the start; RAM and swap already had substantial
usage from other work. Rootless Podman **6.1.1** was used because this user could
not access the Docker socket and passwordless sudo was unavailable. No host
services, permissions or group memberships were changed.

The existing builder image was inspected and reused:

```text
localhost/omarchy-pkg-builder:latest-x86_64-edge
sha256:c1671def8d7d308f36ea7f6223b9e4ec5a870bf8f6fef9dc9fc25fed2ceba2a3
created 2026-09-04 18:08:26 UTC; approximately 1.25 GB
```

Its history follows the repository Dockerfile's Arch bootstrap/base-devel and
Omarchy keyring setup. Its initial pacman configuration has **only `core` and
`extra`**, served through `https://mirror.omarchy.org/$repo/os/$arch`, and its
installed-package inventory has no T2 kernel, header, fan or firmware package.
The builder performs `pacman -Syu` before installing dependencies. There is no
external T2 repository in either build or validation configuration. The
Dockerfile itself was not changed; this run reused its prepared image rather
than reconstructing every image layer. The build containers and source trees
were fresh, not resumed compiler workspaces.

`.BUILDINFO` records GCC `16.2.1+r23+gd564253eb6c8-1`, binutils `2.47-4`, glibc
`2.44+r24+g16be1518495f-1`, make `4.4.1-3`, Rust `1:1.98.1-1`, bindgen
`0.73.0-1`, and pahole `1:1.31-2` from Arch. All external build dependencies
resolved through Arch; Rust registry sources were fetched with the lockfile.

Measured kernel build resources:

* Eight CPUs exposed to `nproc`, with an eight-CPU container quota.
* makepkg started **01:14:03 UTC**, finished **01:37:34 UTC** on September 6
  (21:14–21:37 September 5 locally): **23 minutes 31 seconds**, including source
  retrieval, verification, preparation, compilation and packaging.
* Approximately **175 CPU-minutes** by the final sampled container statistic.
* cgroup memory high-water mark: **13,940,772,864 bytes (12.98 GiB)**, including
  charged file cache. Samples ran every ten seconds near the end; the value is
  the largest observed kernel-maintained peak, not a host-wide RAM peak.
* Largest sampled source/build/package workspace: **30,929,280,155 bytes
  (28.81 GiB apparent size)**. Disk samples ran every twenty seconds near the end,
  so this is an observed lower bound on peak storage, not a guaranteed capacity
  requirement. Leave appreciably more headroom for future kernels/retries.
* Container network statistic: approximately **377 MB received**, including
  package/source downloads. Podman's block-I/O statistic was zero under this
  rootless setup and is not a useful I/O measurement.
* After makepkg cleanup: roughly **393 MiB** in the kernel source workspace,
  and **237 MiB** in the shared output/staging directory.

The audio data package took approximately one second of makepkg time. The fan
daemon took approximately thirteen seconds with two CPUs, including source and
crate fetching. Container startup/key import/upgrade overhead is additional;
separate userspace CPU/memory peaks were not recorded. No bit-for-bit second
kernel compilation was attempted; repeat validation tests artifact reuse.

## Commands and outcomes

Commands were run from the isolated worktree. Local `bin/build` was used after
reviewing `bin/repo`'s SSH forwarding and all upload entrypoints. No publish,
deploy, release, package push, signing, merge or production command was invoked.

```bash
# Fresh kernel source/compile workspace, inspected existing builder image.
CONTAINER_ENGINE=podman OMARCHY_SKIP_BUILDER_IMAGE=1 OMARCHY_BUILD_CPUS=8 \
  bin/build --arch x86_64 --package linux-t2

# Independent fresh userspace container while the kernel was compiling.
CONTAINER_ENGINE=podman OMARCHY_KEEP_BUILD_WORKSPACE=1 \
  OMARCHY_SKIP_BUILDER_IMAGE=1 OMARCHY_BUILD_CPUS=2 \
  bin/build --arch x86_64 --package apple-t2-audio-config t2fanrd

# Fan retry after correcting the source archive's T2FanRD directory casing.
CONTAINER_ENGINE=podman OMARCHY_KEEP_BUILD_WORKSPACE=1 \
  OMARCHY_SKIP_BUILDER_IMAGE=1 OMARCHY_BUILD_CPUS=2 \
  bin/build --arch x86_64 --package t2fanrd

# Final stable-script rerun: succeeds, all three bases/four outputs reused.
CONTAINER_ENGINE=podman OMARCHY_KEEP_BUILD_WORKSPACE=1 \
  OMARCHY_SKIP_BUILDER_IMAGE=1 OMARCHY_BUILD_CPUS=8 \
  bin/build --arch x86_64 --package linux-t2 apple-t2-audio-config t2fanrd

CONTAINER_ENGINE=podman bin/validate-t2
```

Kernel source SHA-256/BLAKE2 checks, configuration hashes and both upstream
signatures passed. All T2 patches applied and required T2 configuration
assertions passed. Kernel and headers were generated and staged together.

The first outer kernel script exited 2 **after** successful makepkg and staging:
the bind-mounted `build/build.sh` had been edited while that long-running shell
was reading it, producing a post-build parser error. The finalized script passes
`bash -n`; its subsequent complete container run exited 0 and reused every
artifact. Do not edit mounted build scripts during builds. The first fan attempt
failed in `prepare()` because GitHub uses the source root `T2FanRD-<commit>`;
the corrected pinned recipe then built successfully in a new container.

Final pacman validation exited **0** and reported:

```text
linux-t2 7.2.3.arch1-1.1
linux-t2-headers 7.2.3.arch1-1.1
apple-t2-audio-config 0.4.r21.ga973d53-1.1
t2fanrd r16.48baf96-1.1
No database errors have been found!
linux-t2: 7716 total files, 0 altered files
linux-t2-headers: 21843 total files, 0 altered files
apple-t2-audio-config: 18 total files, 0 altered files
t2fanrd: 16 total files, 0 altered files
PASS: local pacman transaction, dependencies, modules, initramfs, headers, UCM files and fan service (7.2.3-arch1-Watanare-T2-1.1-t2)
```

The transaction installed the four packages from **`file:///packages/`** and
their missing standard dependencies from Arch: `mkinitcpio 41.1-1`,
`mkinitcpio-busybox 1.36.1-1`, `pahole 1:1.31-2` and
`alsa-ucm-conf 1.2.16.1-1`. Other dependencies were already in the inspected Arch
base image. No `--nodeps`, `--assume-installed`, external binary bootstrap or
firmware substitute was used. The staging database contains all four outputs.

Checks included:

* `pacman -Sp` prints dependency origins, then `pacman -S` consumes the local DB.
  `pacman -Dk` and `pacman -Qkk` pass. Headers explicitly require
  `linux-t2=7.2.3.arch1-1.1`.
* `vmlinuz`, `pkgbase`, header `version` and module vermagic agree. `modinfo`
  verifies `t2bce_core`, `t2bce_dma`, `t2bce_vhci`, `t2bce_audio`, `hci_bcm4377`,
  `brcmfmac`, `applesmc`, `hid_apple` and USB HID support. `apple-bce` is absent.
* A test mkinitcpio image built with Omarchy's early-input module list contains
  `t2bce_vhci`, `t2bce_core`, `t2bce_dma` and `hid-apple.ko.zst`. `usbhid`,
  `hid_generic` and the principal xHCI drivers are built in. `modprobe
  --show-depends` confirms the T2 input dependencies without loading anything.
* A small GPL test module compiles and links with BTF against the **installed**
  headers, and its vermagic matches. It is not loaded.
* `systemd-analyze verify` passes for `t2fanrd.service`; the service remains
  disabled. `ldd` resolves libc, libm and libgcc. The config includes Fan1/Fan2
  and is marked for pacman backup handling.
* All three UCM speaker profiles and their card entry files exist. ALSA
  activation and audio playback require actual T2 hardware and were not tested.

The first validation harness needed corrections to read mkinitcpio's root-only
output and to use `modinfo`'s on-disk `hid-apple` filename rather than its
underscore-normalized module name. The final fresh-container run passed after
those fixes; no package changes were needed.

Expected container limitations remain visible in the logs: autodetection cannot
identify the overlay root, `/etc/vconsole.conf` is absent, and optional AMD,
Nouveau and Renesas firmware is not installed. The dedicated input initramfs
still succeeds, but this is **not** proof of a bootable encrypted-root or Limine
installation. The external header probe emits a harmless missing
`MODULE_DESCRIPTION()` warning. No warnings were suppressed to obtain a pass.

## Reuse and updater tests

```bash
build/test-build-reuse.sh
build/test-sync-t2.sh
bin/sync-upstream self-test
bin/sync-rebuilds --self-test
bin/omarchy-pkgs self-test
bin/omarchy-release self-test
```

All passed locally. Both new fixture tests also passed in the Arch builder
container. The reuse suite covers missing/stale/corrupt split outputs, local
release bumps, and incomplete/mixed published DBs. The actual final container
rerun reports **0 built, 3 bases skipped, 0 failed**; artifact SHA-256 hashes are
unchanged. An invalid `OMARCHY_BUILD_CPUS` value is rejected before running a
container.

`bin/sync-t2 <package> <current-full-commit> --check` reports zero changed files
for each real source pin. An isolated kernel recipe copy with an older version
marker was previewed and imported from `786d47549c81cefadab58e8a6a7d8ec4065a9467`;
the result exactly matched the checked-in recipe/configuration and a second
import was a no-op. This tests import behavior, not compatibility with an
unreviewed future release. Offline fixtures exercise archive commit checking,
successful update, no-op reuse, downgrade and moving-ref rejection. A kernel
patch application failure likewise stops before writing package files.

## Evidence and outstanding work

Full local logs are retained under `logs/`: `t2-kernel-build.log`,
`t2-userspace-build.log`, `t2-fan-build.log`, `t2-all-reuse.log`,
`t2-validation-final.log`, `t2-container-tests.log`, `t2-existing-*-tests.log`,
`t2-update-*.log`, `t2-kernel-update-*.log`, image/inventory/audit files,
per-package `.PKGINFO`/`.BUILDINFO`, and resource JSONL files. Logs and unsigned
archives are gitignored; this report and the JSON records are committed.

Firmware rights/provenance and an actual extraction result remain unresolved.
No physical T2 boot, input, Wi-Fi, Bluetooth, audio, fan or suspend test was run.
The [migration and hardware checklist](README.md#omarchy-settings-and-migration)
must be completed before removing the external repository or enabling routine
publication. Git branch publication does not publish any built package.
