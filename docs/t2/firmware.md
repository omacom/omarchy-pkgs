# Apple/Broadcom firmware: remaining dependency

The missing install-time dependency is **`apple-bcm-firmware 14.0-1`**. The four
other outputs build without it. There is no firmware compilation step: `.bin`,
Bluetooth `.bin`, calibration `.txt`, `.clm_blob` and `.txcap_blob` files are
binary/data inputs extracted from macOS, then renamed and packaged for Linux.

The original recipe is
[`NoaHimesaka1873/apple-bcm-firmware` at `805a1fff70c8d8b8136f24722cd240c529437a78`](https://github.com/NoaHimesaka1873/apple-bcm-firmware/blob/805a1fff70c8d8b8136f24722cd240c529437a78/PKGBUILD).
It downloads `https://mirror.funami.tech/arch-mact2/firmware/bluetooth.tar.gz`
and `wifi.tar.gz`, plus an unpinned fork of `asahi-installer`. All three checksums
are `SKIP`; license is `unknown`, URL is empty, and the description still says
Big Sur despite the 14.0 version and Sonoma-related history. Rebuilding that
recipe would still depend on externally hosted firmware, with insufficient
provenance and verification.

The current finished package was downloaded **for inspection only**, outside
the build worktree and container mounts. Its SHA-256 is
`f2cd47d9e3fb9658f16997b2d9ace3033b57925b8c6ddd86ccc3d07d0c3e9559`.
Its `.PKGINFO` repeats `license = unknown`, `packager = Unknown Packager`, an
empty URL, and build timestamp 1698047430. It has 242 archive entries, including
metadata and directories, and installs firmware under `usr/lib/firmware/brcm`.
It was neither installed nor used as a source/dependency of these builds.

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

Consequently this branch does not add a firmware PKGBUILD claiming a license,
ship an empty replacement that falsely satisfies pacman, or fetch an external
finished package as a build input. Complete install independence requires either
a documented grant for the exact pinned blobs, or a separately reviewed local
extraction and installer migration. Until then, existing automatic T2 installs
still rely on the external firmware package.
