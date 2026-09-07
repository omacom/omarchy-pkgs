# tmog-bin - repackaging a vendor tarball from a versionless URL

## Overview

[TMOG](https://tmog.org/) is a Qt 6 system monitor from Plummers' Software LLC.
There is no source release, no AUR package, and the GitHub repository its
AppStream metadata names (`PlummersSoftwareLLC/TMOG`) is not public, so this
package repackages the vendor's own Linux tarball.

## Why the tarball and not the AppImage

Upstream publishes three Linux artifacts at the same version. The tarball is
7.9 MB and links against the system Qt; the AppImage is 55 MB because it carries
its own copy of Qt, which Omarchy already installs for the shell. The `.deb`
holds the same tree as the tarball under Debian's layout. The tarball is the
same binary at a seventh of the download, so that is what this builds from.

Its layout is already FHS-shaped (`bin/`, `share/applications`, `share/icons`,
`share/metainfo`), so `package()` is a copy rather than a reconstruction. Only
the licence texts move: upstream files them under `share/doc/`, which is
Debian's convention, and on Arch they belong in `share/licenses/`.

## Before this ships publicly

The beta licence in `share/doc/taskmanagerog/copyright` says:

> You may not sell, sublicense, publicly redistribute, or represent the
> software as your own.

Building this package on pkgs.omarchy.org and serving it to users is public
redistribution, so the package needs Plummers' Software's permission before it
is published, not merely a working build. The same file also describes itself as
"a release-candidate document [that] must be approved by the publisher before
public distribution", so the terms themselves may still move.

Nothing in the packaging depends on the answer -- it is a question for the
publisher, and it is recorded here so it is not mistaken for settled.

## The versionless download URL

Every TMOG release is served from one path:

```text
https://tmog.org/downloads/TMOG-Task-Manager-Linux-x86_64.tar.gz
```

Nothing in it identifies a version, and `downloads/release.json` -- the manifest
the macOS updater verifies -- describes the DMG only. So the Linux side has no
manifest to read a checksum out of, and `.omarchy/upstream.sh` computes one from
the artifact. That download is 7.9 MB and happens only when `/version.txt`
reports something other than the checked-in `pkgver`, so the six-hourly check
normally costs a single small request.

Two details follow from the path being mutable:

- **The `?v=<version>-free` query string** in `source=()` is upstream's own
  cache key; tmog.org appends it to its Linux download links for the same
  reason, so a CDN holding an older object under this path cannot answer for a
  new release.
- **The hook checks the tarball's top-level directory**, which upstream names
  `TaskManagerOG-<version>-linux-x86_64`. It is the only evidence available that
  the bytes that arrived are the release `/version.txt` announced. On a mismatch
  the hook reports no update and leaves the package alone, which is the right
  answer whether the cause is a half-published release or a stale object.

`sha256sums` is reported under the key `any` rather than `x86_64`: upstream
publishes no aarch64 build, so the package has one plain `source=()` array, and
`any` is `bin/sync-upstream`'s name for the unsuffixed checksum array.

## Testing

```bash
bin/sync-upstream tmog-bin
bin/repo build --package tmog-bin
```
