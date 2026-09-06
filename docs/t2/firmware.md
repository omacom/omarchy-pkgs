# Apple/Broadcom firmware

`apple-bcm-firmware 14.4.1-1.1` now builds locally from an **Omarchy-owned fork**
of the actual firmware tree, with no Funami archive or finished arch-mact2
package as an input. The isolated five-package pacman transaction succeeds.
These are packaged Apple/Broadcom blobs and calibration data, not firmware
compiled by Omarchy. Redistribution rights and hardware operation remain
unresolved release requirements.

## Controlled source and exact coverage

[omacom/apple-bcm-firmware](https://github.com/omacom/apple-bcm-firmware) is a fork
of [AdityaGarg8/Apple-Firmware](https://github.com/AdityaGarg8/Apple-Firmware).
Git history and upstream attribution are retained. The fork was created for
this work; its Actions permissions were explicitly set to `enabled: false`,
and it has no releases. The inherited Debian publishing workflow is inactive.
Do not enable it: it publishes packages and references the original author's
repository and secrets. Maintenance here uses reviewed Git trees and
`omarchy-pkgs/bin/sync-t2`, not upstream Debian/RPM release assets.

The source pin is
[`dc061b535d53e293cdd5793c1255faaca197574b`](https://github.com/omacom/apple-bcm-firmware/tree/dc061b535d53e293cdd5793c1255faaca197574b).
The firmware files last changed in
[`8dce96552f774a00e0009b3187563fedb6b0beed`](https://github.com/omacom/apple-bcm-firmware/commit/8dce96552f774a00e0009b3187563fedb6b0beed),
“Update to Sonoma 14.4.1”. That is the package version even though newer
upstream release assets exist: those assets do not describe the checked-in tree.
The fork's full-commit archive SHA-256 is
`c66b9c37a73fdd2fa7a11ea7b177edfca9b85fd33f87557c9fb5e3640398671d`.

The upstream README identifies a **macOS GitHub Runner Image** as the extraction
source. It does not record the exact runner image identifier or original Apple
image hashes. This gives a documented extraction origin and immutable received
files, but not a fully reproduced chain from an Apple recovery image. A future
refresh should capture those inputs as well as the resulting filenames/hashes.
The extraction/renaming work is attributed to Aditya Garg and the t2linux/Asahi
contributors; their tool licenses do not grant rights to the firmware itself.

The package contains exactly **132 nonempty Intel firmware files**, totaling
**20,639,588 bytes**, selected from 168 files in the upstream tree:

| Family | Files | Purpose |
| --- | ---: | --- |
| brcmfmac4355c1 | 7 | Wi-Fi firmware and board calibration |
| brcmfmac4364b2 | 72 | Wi-Fi firmware and board calibration |
| brcmfmac4364b3 | 36 | Wi-Fi firmware and board calibration |
| brcmfmac4377b3 | 15 | Wi-Fi firmware and board calibration |
| brcmbt4377b3 | 2 | Bluetooth firmware and PTB data |

All 132 Intel filenames match the Intel subset of the existing `14.0-1` package.
Apple Silicon families are deliberately excluded. This includes `.bin`, `.ptb`,
`.txt`, `.clm_blob` and `.txcap_blob` data, retaining their Linux driver names.
The checked-in [manifest](../../pkgbuilds/apple-bcm-firmware/intel-firmware.sha256)
pins every installed file. `makepkg` verifies the archive and local sources;
`check()` verifies all file hashes. Container validation compares the installed
manifest with the checked-in one, verifies installed bytes and the exact file
set, and installs alongside Arch's `linux-firmware-broadcom` without conflicts.
No module reload hook, install script, service or boot configuration is added.
Filename coverage alone does not prove device/model operation.

## Earlier arch-mact2 provenance

Forking the original
[`NoaHimesaka1873/apple-bcm-firmware` recipe](https://github.com/NoaHimesaka1873/apple-bcm-firmware/blob/805a1fff70c8d8b8136f24722cd240c529437a78/PKGBUILD)
would not remove Funami dependence: it contains no firmware and downloads
`https://mirror.funami.tech/arch-mact2/firmware/{wifi,bluetooth}.tar.gz` plus an
unpinned Asahi installer fork. All three checksums are `SKIP`; license is
`unknown`. The raw archives contain no license/readme/notice files. Their
SHA-256 hashes, inspected outside builders, are:

* Wi-Fi: `91d5d734f27ea1812a6b3c23f469f69d38b1f39a605420fe89acc5df90b380f8`
* Bluetooth: `0e4ac278d2e2dc38a700c23c233063007cb37887d59386ac78f073f28680ea3f`

The finished `apple-bcm-firmware-14.0-1-any.pkg.tar.zst` was downloaded **only
for inspection**, outside build mounts, and never installed or used as a build
input. SHA-256:
`f2cd47d9e3fb9658f16997b2d9ace3033b57925b8c6ddd86ccc3d07d0c3e9559`.
Its metadata declares `license = unknown`, `packager = Unknown Packager`, an
empty URL and build timestamp 1698047430. Its 242 archive entries include 235
firmware files plus metadata/directories; comparison uses the 132 Intel files.

## Extraction provenance

The [t2linux Wi-Fi/Bluetooth guide](https://wiki.t2linux.org/guides/wifi-bluetooth/)
documents five methods. The preferred ownership boundary is extraction from a
user's local macOS firmware tree (`/usr/share/firmware`) or an Apple recovery
image, on that user's machine, retaining a record of the macOS version/build,
Apple source URL or local source, tool commits, input hashes and output manifest.

For a Mac with macOS, the guide's **method 2** creates `firmware.tar` from the
local firmware tree; method 3 can create a local pacman package. For a Mac with
macOS removed, **method 5** downloads an Apple recovery image using the
`kholia/OSX-KVM` recovery fetcher, converts it with `dmg2img`, mounts its firmware
tree, and runs the Asahi-derived renamer. Monterey, Ventura or Sonoma is needed
for complete Wi-Fi/Bluetooth data. The guide excludes iMac19,1, iMac19,2 and
iMacPro1,1 from methods 4/5; those require local macOS extraction. Model-specific
calibration and NVRAM quirks mean one generic archive is not proof of coverage.

The reviewed guide/tool snapshot is `t2linux/wiki` commit
[`82ceb5835a25fc6eb88fc68bc4d68c574a0ab4ff`](https://github.com/t2linux/wiki/tree/82ceb5835a25fc6eb88fc68bc4d68c574a0ab4ff);
`docs/tools/firmware.sh` last changed at
`11fc0a8d8cfb61affd0cb9d1ac245c1b6c16d3cd`. That script credits Aditya Garg,
Orlando Chamberlain, Sharpened Blade and the Asahi Linux contributors and carries
an MIT license for the **tool**, not for Apple's firmware.

To reproduce the reviewed local-macOS method, inspect that pinned script,
then run it on the target Mac and select the local tarball method:

```bash
git clone https://github.com/t2linux/wiki.git t2linux-wiki
git -C t2linux-wiki checkout --detach 82ceb5835a25fc6eb88fc68bc4d68c574a0ab4ff
less t2linux-wiki/docs/tools/firmware.sh
bash t2linux-wiki/docs/tools/firmware.sh
# On macOS: select method 2; retain ~/Downloads/firmware.tar for this Mac.
shasum -a 256 ~/Downloads/firmware.tar
```

The recovery branch currently downloads its helper from a moving `master` URL
and uses privileged loop mounts. It has **not** been executed here. A maintained
recovery pipeline must first pin that helper, verify the Apple recovery
chunklist/image, make extraction local and reviewable, and hash the exact
renamed outputs. Do not run the existing interactive script in an automated
package build or feed its output into a public package without resolving rights.
No target Mac firmware tree or validated recovery image was available in this
workspace, so extraction, model coverage and actual firmware loading were not
validated. A user-extracted archive would be a locally generated artifact, not
firmware compiled by Omarchy.

## Redistribution finding

The recipe offers no redistributable firmware license. Apple's
[macOS Sonoma license](https://www.apple.com/legal/sla/docs/macOSSonoma.pdf),
sections 2.J–2.K, restricts redistribution of Apple Software and says that Apple
Boot ROM code and firmware may not be copied, modified or redistributed (subject
to the agreement's terms and other licenses). A public download endpoint and
the MIT license of the extraction tool do not grant redistribution rights to
the extracted blobs. This review found no separate Apple/Broadcom grant covering
the precise files in this package; this is an unresolved release requirement,
not a conclusion that every possible local use is prohibited.

The Omarchy fork also has no separate license grant for these exact files.
The new PKGBUILD records `LicenseRef-unknown` and packages a provenance note;
it does not claim the extraction tool's MIT license for the firmware. Forking
controls availability and history but does not resolve redistribution rights.
All four package bases remain `skip_build: true`, and no built package was
signed or published. Local technical dependency closure is complete; retiring
the production external firmware dependency still requires the rights decision,
or a reviewed on-device extraction path, followed by hardware qualification
and installer/channel migration.
