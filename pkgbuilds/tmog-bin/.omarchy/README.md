# tmog-bin - repackaging a versioned vendor tarball

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

## Where releases come from

Since 1.0.0 the site lives under `/rtm/`, and each Linux artifact is published
under a versioned name with a `.sha256` sidecar beside it:

```text
https://tmog.org/rtm/downloads/release-linux.json
https://tmog.org/rtm/downloads/TaskManagerOG-<version>-linux-x86_64.tar.gz
https://tmog.org/rtm/downloads/TaskManagerOG-<version>-linux-x86_64.tar.gz.sha256
```

`.omarchy/upstream.sh` reads the version from the Linux x86_64 manifest,
validating its schema, platform, architecture, and version. The shared
`version.txt` can advance before Linux artifacts are published (it announced
1.0.1 while the Linux manifest and artifacts were still at 1.0.0).

The Linux manifest's checksum describes the AppImage, not the tarball, so the
hook still reads the tarball's checksum from its own sidecar and checks that
the sidecar names the requested artifact. Missing or invalid manifests and
checksums fail the sync; there is no fallback to the shared version or an
unchecked download. An unchanged Linux version costs one small request; an
update costs two, and neither downloads the tarball.

Up to 0.1.1 every release was served from one versionless path,
`/downloads/TMOG-Task-Manager-Linux-x86_64.tar.gz`, and the hook downloaded it
to compute a checksum. That path now returns 404, which is what broke the
upstream sync when 1.0.0 shipped.

`sha256sums` is reported under the key `any` rather than `x86_64`: the package
builds x86_64 alone, so it has one plain `source=()` array, and `any` is
`bin/sync-upstream`'s name for the unsuffixed checksum array. Upstream began
publishing an aarch64 tarball (with its own sidecar) at 1.0.0; adding it means
moving to `source_x86_64`/`source_aarch64` and reporting both keys.

## Testing

```bash
bash pkgbuilds/tmog-bin/.omarchy/upstream-test.sh
bin/sync-upstream self-test
bin/sync-upstream tmog-bin
bin/repo build --package tmog-bin
```
