# How a package builds

`bin/build` is the one builder: PR builds, rebuilds at merge and local builds
all call it.

## Dependency resolution

Within one `bin/build` run, the build system handles dependencies between the
packages it was asked to build. CI builds each package in its own job, so a
PR's packages do not see each other's fresh builds; they resolve from `edge`.

1. Plans dependency order once, including `depends`, `makedepends`,
   `checkdepends`, and their architecture-specific arrays.
2. Builds each package in a fresh container. Installed packages and changes
   to the container's system files cannot carry over to the next build.
3. Shares successful artifacts through the temporary `[omarchy-build]` repo,
   installing newly built prerequisites in each consumer's container.
4. Blocks consumers of a failed prerequisite while continuing independent
   builds.

Example: `steam` on aarch64 depends on `gtk2`, so `gtk2` is built first.

Isolation also lets the release and dev Omarchy pairs build in the same run:
Flea can install `omarchy` without preventing `omarchy-dev` from installing
its conflicting settings package in a different container.

Pacman downloads are cached under `cache/pacman/<channel>/<arch>/` across
containers and runs, where `<arch>` is the builder's architecture. The installed package database is never shared. Each
container updates its base system before resolving build dependencies, so a
cached builder image cannot cause a partial system upgrade. The existing
`OMARCHY_KEEP_BUILD_WORKSPACE`, `OMARCHY_SKIP_BUILDER_IMAGE`, and
`OMARCHY_DEFER_RUNTIME_DEPS` flags retain their behavior.

`tests/build-isolation.sh` exercises conflicting package pairs, failed
prerequisites, resumed builds, cache replacement, and deferred dependencies
using real containers and pacman transactions. It uses the prepared builder
image, or an image named by `TEST_BUILDER_IMAGE`; CI builds the small fixture
image in `tests/build-isolation.Dockerfile`.

## Daily builder images

`Refresh builder images` builds fresh `edge` environments daily at 04:23 UTC,
when their inputs change on `master`, and on manual dispatch. x86_64 and
aarch64 build on native GitHub-hosted runners, without occupying the DO
package-builder pool. Each candidate must pass `tests/build-isolation.sh`,
including real package builds, before publication to
`ghcr.io/omacom/omarchy-pkg-builder`. Only `master` in this repository can
publish; PR workflows cannot replace the shared images.
PRs that change image inputs also build and test both candidates on native
runners, with a read-only token and no registry publication.

The compatibility tag contains the architecture, mirror, and a hash of the
entire `build/` context, including executable bits and symlink targets but
excluding checkout timestamps, ownership and the other permission bits a
checkout's umask decides. This deliberately invalidates
images when mounted build scripts change too. `v1` identifies the image build
contract; change it if the invocation or compatibility rules change. Each
successful refresh also gets a run-specific tag for diagnosis and rollback.
A failed build, isolation test, or push leaves the previous compatible image
selected. Scheduled builds use `--pull --no-cache` so unchanged Dockerfiles
still pick up fresh Arch packages.

To build and test a candidate locally:

```bash
bin/builder-image key --arch x86_64 --mirror edge
bin/builder-image build --arch x86_64 --mirror edge --tag builder-candidate:test --fresh
CONTAINER_ENGINE=docker TEST_BUILDER_IMAGE=builder-candidate:test tests/build-isolation.sh
```

The workflow uses its repository `GITHUB_TOKEN` with `packages: write`; no
registry PAT is needed. **One-time setup when the image package is first
created:** GHCR
creates the package private. In the `omacom/omarchy-pkg-builder` package
settings, change visibility to **Public**, then rerun the failed refresh job.
The workflow checks anonymous registry access before advancing the compatible
tag, so fork PRs will not be directed to an image they cannot pull. Subsequent
refreshes preserve that package visibility.

`publish.yml`, `promote.yml`, `release-rc.yml` and `unpublish.yml` pull the
compatible image to sign and update databases, and build it on the runner when
no image carries the key yet (a change to `build/` publishes before its image
refresh has finished). Package build jobs in `build-pr.yml` pull it the same
way, for their own architecture, and build it only when no image carries the
key.

## Cross builds

A package builds in the builder image of its target architecture, natively or
under QEMU. `package_build_host` names the exception: chromium for aarch64
builds in the x86_64 image, because Chromium pins its clang, Rust and Node for
x64 hosts only. Google builds Chrome for Linux arm64 the same way.

`bin/build` then runs the x86_64 builder image and passes `BUILDER_ARCH` to
`build/build.sh`, which differs from `ARCH` only in a cross build:

- makepkg reads a copy of `makepkg.conf` with `CARCH` and `CHOST` for the
  target, so it names and checks the package for aarch64.
- makepkg's strip step is off. The builder's GNU strip reads only x86_64
  objects, so a cross recipe strips with its own toolchain: chromium uses
  the `llvm-strip` its DEPS pins.
- `makepkg -s` still installs the recipe's dependencies, in their x86_64
  builds. Host tools the build runs link them: V8's snapshot generator
  needs `libxcb`.
- pacman takes Omarchy's tree or channel for the builder's architecture,
  never the target's, and never the run's own `omarchy-build` repository:
  its aarch64 packages cannot run here. A package that needs another package
  built in the same run cannot cross build.
- A dry run plans every requested package, whatever builder it needs. A real
  run uses one builder image, so `bin/build` refuses a selection that mixes
  builders.

The fast-ring check runs the package in the aarch64 builder image under QEMU.
`bin/check-fast-ring` builds that image when it is missing: a cross build
leaves only the x86_64 one.
