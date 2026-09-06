# Omarchy Package Repository

Build system for the Omarchy Package Repository. Builds PKGBUILDs from local sources and AUR, signs them, and syncs to production.

**Multi-Architecture**: Supports both x86_64 and aarch64 (ARM64).

## PKGBUILDs

Each package lives directly under `pkgbuilds/<package>/` and carries Omarchy metadata in `.omarchy/package.json`.

The filesystem no longer encodes release policy. Instead:

- there are three channels forming a forward-only pipeline: `edge` → `rc` → `stable`
- all packages build for `edge` unless their metadata pins `channels`
- packages with `"release_ring": "fast"` build natively for **all three** channels —
  each in its own image against its own base mirror, because rc's Arch snapshot may sit
  anywhere between stable's and edge's, so an artifact linked against stable's libraries
  is not necessarily correct for rc
- a release train opens by advancing edge into rc (`bin/repo advance --from edge --to rc`)
  and ships by promoting rc into stable (`bin/repo advance --from rc --to stable`)
- the release pair (`omarchy`, `omarchy-settings`) is marked `"pinned": true`: its version
  is set per release on the standing `rc` branch, so only a build from that branch's worktree
  (`OMARCHY_RC_PINS=1`, which `omarchy-release rc` sets) may build it for rc — master's
  shipped pins can never overwrite an in-flight RC. The dev pair
  (`omarchy-dev`, `omarchy-settings-dev`) is pinned to `edge`
- AUR sync behavior is controlled by `source`, `sync`, `aur`, patches, and hooks in `.omarchy/`
- packages can opt out of unscoped builds with `skip_build`; explicit `--package` builds remain available
- packages that follow a vendor release feed instead of the AUR carry an `.omarchy/upstream.sh` hook

## Prerequisites
### aarch64 Builds (Optional)

The repository host builds every architecture it publishes on the same
machine. A foreign architecture runs under QEMU user emulation, which
`bin/build` checks by actually running a container for the target platform.
Rootful Docker registers QEMU on first use. Rootless Podman uses the host's
registration and prints the one-time Arch setup commands when it is missing or
lacks the credential flag required by `sudo` inside the builder:

```bash
# Verify
podman run --rm --platform linux/arm64 docker.io/library/alpine:latest uname -m
# Should output: aarch64
```

**Note**: emulated builds are much slower than native ones.

### Published architectures

`helpers/paths.sh` names the architectures this repository publishes:

```bash
PUBLISHED_ARCHES="${OMARCHY_ARCHES:-x86_64}"
```

That list drives the whole scheduled pipeline. `check-versions` compares
PKGBUILDs against each architecture's channel databases and writes one queue
file per channel and architecture (`.sync-needed-<channel>-<arch>`);
`auto-release <channel>` works through the queues one architecture at a
time, each with its own backoff (`.build-failed-<channel>-<arch>`), so a
failing build on one architecture never holds up the other; and the release
train advances channels with `--arch all`: it takes one host-wide lock and
verifies every architecture's source database before moving any of them. The
first entry is the reference architecture the release train observes channels
through. A remote sync failure can still leave a promotion temporarily partial;
rerunning the same advance completes it safely.

Adding an architecture to the scheduled pipeline is therefore one checked-in
change to that list: the next `check-versions` tick queues everything the new
architecture lacks, and the next `auto-release` tick starts building it. A
checked-in list also means the rebuild workflow and release host cannot drift
onto different architecture sets. For a one-off run, override it directly:

```bash
OMARCHY_ARCHES=x86_64 bin/check-versions
OMARCHY_ARCHES=aarch64 bin/check-versions
OMARCHY_ARCHES="x86_64 aarch64" bin/check-versions
```

The builder image bootstraps
`omarchy-keyring` from the x86_64 tree for every architecture, so the first
build of a new architecture does not depend on a repository that only it can
create.

## Quick Start

### Cutting an Omarchy release

`bin/omarchy-release` is the front door. A release train has three human
moments, each one command — and bare `omarchy-release` observes reality
(branches, pins, published channels, tags) and walks you to the next one:

```bash
bin/omarchy-release              # shepherd: status + guided next step
bin/omarchy-release start 4.0.2  # open the train: branch v4-0-2 + staging PR
bin/omarchy-release pick         # choose merged PRs to cherry-pick (multi-select)
bin/omarchy-release rc           # publish the next 4.0.2rcN to the rc channel
bin/omarchy-release ship         # tag, final pins, promote rc → stable,
                                 # draft GitHub release, ISO, website — one swoop
bin/omarchy-release doctor       # verify credentials/connections up front
```

Versions are inferred from branch names (`v4-0-2` ⇒ `4.0.2rcN` ⇒ tag
`v4.0.2`); `start` is the only place a version is typed. Every command is
idempotent — re-runs skip whatever is already done. `ship` refuses to promote
a commit no RC was cut from.

### Full release

Ship the tested rc channel to stable (copies packages + signatures, then
cleans, rebuilds the database, and syncs):

```
bin/repo advance --from rc --to stable
```

Open a release train that ships new edge packages by carrying edge into rc
first:

```
bin/repo advance --from edge --to rc
```

### Complete Workflow

The release command is smart and **incremental** - it only builds packages that have changed or are missing. You generally don't need to specify a package manually unless you are debugging a specific failure.

```bash
# Build changed/new packages, sign, promote, clean, update, and sync
bin/repo release

# Stable Mirror
bin/repo release --mirror stable

# ARM64
bin/repo release --arch aarch64

# Force build specific package (useful for debugging failures)
bin/repo release --package omarchy-nvim

# Show what would build without signing/promoting/syncing
bin/repo release --dry-run
```

### Step-by-Step

```bash
bin/repo build                          # Build (unsigned)
bin/repo sign                           # Sign packages
bin/repo promote                        # Copy to production
bin/repo clean                          # Remove old versions
bin/repo update                         # Update database
bin/repo sync                           # Sync to remote
```

### Building Heavy Packages Locally

Large packages build faster on a local machine than on the server. Build them
here, then hand the artifacts to the repository host, which signs and publishes
them:

```bash
bin/repo deploy --package nvidia-580xx-utils   # Build here, publish from the host
```

`deploy` is `build` followed by `push`. The two steps are also available
separately when a build needs inspecting before it ships:

```bash
bin/repo build --package nvidia-580xx-utils    # Build on the fast machine
bin/repo push --package nvidia-580xx-utils     # Upload + publish on the host
```

`push` uploads to the host's `build-output/`, verifies checksums, and runs
`bin/upload-prebuilt` there. Do not publish from a local checkout instead: only
the repository host holds the complete repository and the signing key.

**Name the package.** `build` asks the local repository database which packages
are already built, and a build machine has no such database, so an unscoped run
treats every package as out of date and rebuilds the whole repository. `deploy`
refuses to run unscoped when that database is missing. Unscoped builds belong on
the repository host, where `bin/repo release` does the same job against a real
database.

Every other command in `bin/` — `sign`, `promote`, `update`, `clean`,
`advance`, `remove`, `sync`, `release` — works on the published tree. Run them
from anywhere: with a repository host configured they forward over ssh and run
there (see [Build trigger and the build host](#build-trigger-and-the-build-host)),
and `--local` forces execution on the current machine. `build`, `push` and
`deploy` are the three meant to run on a build machine rather than the host.

## Commands

### Global Flags

These flags can be used with all commands:

- `--mirror <edge|rc|stable>`: Selects the channel (default: `edge`).
- `--local`: Run on this machine instead of forwarding to the repository host.
- `--arch <x86_64|aarch64>`: Selects the target architecture (default: `x86_64`).

### Build

```bash
bin/repo build                                   # All packages (x86_64, edge)
bin/repo build --arch aarch64                    # ARM64
bin/repo build --mirror rc                       # Release-candidate channel
bin/repo build --mirror stable                   # Stable channel
bin/repo build --package yay cursor-bin          # Specific packages
bin/repo build --dry-run                         # Show what would build
```

**Output**: Unsigned `.pkg.tar.zst` in `build-output/`. Only builds packages that are newer than what is in the repository.

Use `--dry-run` to show the build plan without running `makepkg`.

### Sign

```bash
bin/repo sign
```

Fetches GPG key from 1Password or environment, signs all packages in `build-output/`. Supports `--arch` and `--mirror`.

### Promote

```bash
bin/repo promote                    # Copy to production
bin/repo promote --arch aarch64     # ARM64
bin/repo promote --dry-run          # Preview
```

Copies signed packages from `build-output/` → `pkgs.omarchy.org/`.

### Clean

```bash
bin/repo clean                      # Keep 2 versions
bin/repo clean --keep 3             # Keep 3 versions
bin/repo clean --dry-run            # Preview
```

Removes old package versions from the file system. **Does not update the database.**

### Update

```bash
bin/repo update                     # Update database
```

Updates the repository database (adding the newest version of each package). Run this after `promote` or `clean`.

### Sync Repository

```bash
bin/repo sync                           # Sync current arch/mirror
bin/repo sync --mirror stable           # Sync stable
bin/repo sync --arch aarch64            # Sync ARM64
bin/repo sync --skip-prod-check         # No confirmation
bin/repo sync --prune                   # Also delete remote packages missing locally
```

Syncs package repositories to the remote server using rclone based on the configured mirror and architecture.

**Uploads are additive.** A local tree is not authoritative about what belongs on
the remote — `pkgs.omarchy.org/` is gitignored, and packages built on another
machine exist only there — so sync never deletes by default. Removing packages
from the remote requires `--prune`, which only makes sense from a complete tree.

For the same reason sync refuses to publish a repository database built from a
tree holding fewer packages than the remote database already lists. The database
is what pacman resolves against, so a partial one hides every package it does not
know about even though the files are still on the mirror. Use `bin/repo push` to
publish packages built on another machine.

### Deploy

```bash
bin/repo deploy --package nvidia-580xx-utils   # Build locally, publish from the host
bin/repo deploy --host root@example.com        # Point at a specific repo host
bin/repo deploy --dry-run                      # Show the plan, change nothing
```

Runs `build` then `push` in one command. The repository host is resolved before
the build starts, so a missing `--host` fails immediately rather than after a long
compile.

### Push to the Repository Host

```bash
bin/repo push                                  # Push everything in build-output
bin/repo push --package nvidia-580xx-utils     # Push one package
bin/repo push --mirror stable --arch aarch64   # Pick mirror and architecture
bin/repo push --host root@example.com          # Override the repo host
bin/repo push --dry-run                        # Show the plan, transfer nothing
```

Uploads packages from `build-output/` to the repository host and publishes them there
with `bin/upload-prebuilt` (sign → promote → update → sync). Use it when a package
is quicker to build on a local machine than on the server.

Publishing happens on the host rather than locally for two reasons: the GPG
signing key lives there and nowhere else, and only the host holds the complete
repository that a correct database and sync require. Local machines therefore
need no secrets.

The host comes from `--host`, `$OMARCHY_REPO_HOST`, then `.repo-host`. One
machine both serves pkgs.omarchy.org and runs the scheduled builds, so the
setting is named for the repository rather than for building, which happens
wherever you like. The same setting tells `bin/omarchy-pkgs release` which host
to poke after a release push.

`--package` means the same thing as it does to `build`: a pkgbase, whose every
output ships together. Pushing `nvidia-580xx-utils` carries `nvidia-580xx-dkms`
and `opencl-nvidia-580xx` with it, because that is what the build produced. An
output's own name still selects just that one, for publishing a single package
on purpose. Omit `--package` to push everything built.

Publishing signs and promotes everything staged on the host, not just what this
push uploaded, so `push` stops when it finds packages already staged there —
usually leftovers from a failed run. Remove them on the host, or pass
`--include-staged` to publish them too.

### Sync AUR PKGBUILDs

```bash
bin/sync-aur                            # Sync all AUR packages with sync enabled
bin/sync-aur yay v4l2-relayd            # Sync specific packages
```

AUR sync is metadata-driven. It preserves `.omarchy/`, replaces the package root with AUR contents, applies `.omarchy/patches/*.patch`, runs `.omarchy/post-sync.sh` when present, applies pkgrel metadata, removes AUR-only `.SRCINFO` and `.gitignore` files, and records `upstream_commit`.

### Sync Upstream Releases

```bash
bin/sync-upstream                       # Update every package with an upstream hook
bin/sync-upstream openai-codex-desktop  # Update specific packages
```

Some vendors publish a release feed of their own that is faster and more precise
than the AUR packaging of it. Those packages are `source: local` — Omarchy owns
the PKGBUILD — and declare where releases come from either as data or, for an
unusual feed, a small hook.

A vendor shipping tagged GitHub releases is pure data, declared as `upstream`
in `.omarchy/package.json` with no code at all:

```json
"upstream": {
  "github": "jdx/mise",
  "checksums": "SHASUMS256.txt",
  "assets": {
    "x86_64": "mise-{tag}-linux-x64.tar.xz",
    "aarch64": "mise-{tag}-linux-arm64.tar.xz"
  }
}
```

`checksums` names the manifest asset the vendor publishes. A vendor publishing
none sets `"digests": true` instead, and the checksums come from the SHA-256
digest GitHub's release API reports for every asset — see
`pkgbuilds/schist-bin/.omarchy/package.json`. Either way the artifacts
themselves are never downloaded.

An architecture may map to an ordered array when its PKGBUILD downloads more
than one release asset. Small versioned files outside the release assets can be
listed under `sources` and are downloaded and hashed when a new version appears:

```json
"upstream": {
  "github": "owner/project",
  "digests": true,
  "assets": {
    "x86_64": ["tool-{pkgver}-x86_64", "tool-{pkgver}-x86_64.asc"],
    "aarch64": ["tool-{pkgver}-aarch64", "tool-{pkgver}-aarch64.asc"]
  },
  "sources": {
    "any": ["https://raw.githubusercontent.com/owner/project/{tag}/LICENSE"]
  }
}
```

Asset and source keys must be disjoint because each key maps to one PKGBUILD
checksum array (`any` means the unsuffixed `sha256sums`).

Repositories whose historical releases use incompatible tag schemes may set
`"latest_only": true`. The provider then considers only the newest stable
GitHub release, while retaining all validation for that release. A quarantine
will wait for that release to age instead of falling back to an older one.

`{tag}` and `{pkgver}` interpolate into asset names; a leading `v` on the tag is
stripped for `pkgver`; drafts and prereleases are ignored. Only the 100 most
recent releases are considered. The provider fails closed on anything it cannot
read — an unusable tag, timestamp, or checksum stops the sync rather than being
skipped.

Projects that publish version tags but no checksum manifest can declare the
tag repository, the exact tag shape, and every source that should be hashed:

```json
"upstream": {
  "git_tags": "https://github.com/owner/project.git",
  "tag_pattern": "v{pkgver}",
  "sources": {
    "any": ["https://github.com/owner/project/archive/refs/tags/{tag}.tar.gz"]
  }
}
```

The newest matching tag is selected with pacman's `vercmp`; unrelated tags are
ignored. `tag_pattern` must contain exactly one `{pkgver}`. Source templates may
use `{tag}` and `{pkgver}`. Each expanded URL must be HTTPS and is downloaded
only when the discovered version is newer. A checked-in patch or other local
source can be included as `file:patch-name.patch`; it is hashed from the package
directory. Keys such as `any`, `x86_64`, and `aarch64` select the corresponding
`sha256sums` array.

npm packages use the same source mapping, with `{npm_tarball}` available for
the tarball named by the selected dist-tag:

```json
"upstream": {
  "npm": "@scope/package",
  "dist_tag": "latest",
  "sources": {
    "any": ["{npm_tarball}", "https://example.com/v{pkgver}/CHANGELOG.md"]
  }
}
```

`dist_tag` defaults to `latest`. The registry's publication timestamp is
carried into the provider result, so `min_release_age` works for npm packages.

A vendor with a plain-text Debian `Packages` index can use it to discover the
newest exact package version, then hash immutable source URLs:

```json
"upstream": {
  "debian": "https://example.com/debian/dists/stable/main/binary-amd64/Packages",
  "package": "example-app",
  "sources": {
    "x86_64": ["https://example.com/tool-{pkgver}-x64.tar.gz"],
    "aarch64": ["https://example.com/tool-{pkgver}-arm64.tar.gz"]
  }
}
```

This deliberately accepts only Debian versions that are already valid Arch
`pkgver` values. Feeds needing epoch, revision, or filename translation retain
a hook. Exactly one of `github`, `git_tags`, `npm`, or `debian` may appear in a
declaration.

A timestamped provider may also declare `"min_release_age": "24h"`
(`s`/`m`/`h`/`d` suffix or bare seconds) to quarantine fresh releases until
maintainers have had time to pull a bad or compromised one. GitHub Releases and
npm provide publication times; raw git tags and Debian Packages indexes do not,
so combining either with this policy fails closed. The newest release that has
cleared the window ships, so a fast release cadence cannot starve updates. The
window is enforced
centrally: whatever reports the release must prove its age via `published_at`,
or the sync fails. A maintainer deliberately shipping inside the window runs
`BYPASS_MIN_RELEASE_AGE=1 bin/sync-upstream <package>` locally and merges the
result through a normal PR; scheduled automation never sets the bypass.

A vendor whose feed fits no convention (a Debian package index, a bare
version.txt) instead provides `.omarchy/upstream.sh`, a hook that reports the
newest upstream release as JSON on stdout — declaring both an `upstream` block
and a hook is an error:

```json
{
  "pkgver": "1.2.3",
  "sha256sums": { "x86_64": ["<sha256>"], "aarch64": ["<sha256>"] }
}
```

Architecture keys become `sha256sums_<arch>` in the PKGBUILD; the key `any` means
the unsuffixed `sha256sums` array, and only the arrays a hook names are touched.
An empty object (`{}`) reports no update, which is how a hook waits out a release
that has landed for one architecture but not yet the other.

A vendor whose download URLs carry more than the version — a build hash, a
release id — keeps that in an underscore-prefixed PKGBUILD variable and has the
hook report it under `vars`, for example `"vars": { "_commit": "<hash>" }`
(see `pkgbuilds/grok-bot/.omarchy/upstream.sh`). Only `_`-prefixed names with
plain token values are accepted, so a hook can never reach `pkgver`, `source`
or anything else makepkg owns.

When the reported version is newer than the checked-in one, `bin/sync-upstream`
rewrites `pkgver`, those checksum arrays and any reported vars, and resets
`pkgrel` to 1. A version
that is equal or older leaves the package alone, so a vendor rolling a release
back cannot walk the repository backwards.

Hooks should read checksums from whatever manifest the vendor publishes rather
than downloading the artifacts — see `pkgbuilds/openai-codex-desktop/.omarchy/upstream.sh`,
which reads OpenAI's Debian package index and never fetches the 750 MB of debs
it describes. Hooks honoring `min_release_age` receive the window as
`MIN_RELEASE_AGE_SECONDS` and report `published_at` alongside `pkgver`.

`bin/sync-upstream self-test` runs offline fixture tests over the release
selection, quarantine backstop, duration parsing, and manifest validation.

### Sync Rebuild Triggers

```bash
bin/sync-rebuilds                       # Bump every package whose dependencies moved
bin/sync-rebuilds quickshell-git        # Update specific packages
bin/sync-rebuilds --self-test           # Run the regression tests
```

Some packages have to be rebuilt when something they link against changes, even though nothing in their own source moved. A Qt private-API consumer is the usual case: `Qt_6_PRIVATE_API` symbols are not covered by the soname, so a qt6-base point release can leave an installed binary unable to resolve a symbol at startup, and pacman upgrades Qt out from under it because the dependency is unversioned. The package still builds from the same git commit, so nothing in the normal version check notices.

A package names those dependencies in `.omarchy/package.json`:

```json
{ "source": "aur", "sync": false, "rebuild_on": ["qt6-base", "qt6-declarative", "qt6-wayland"] }
```

`bin/sync-rebuilds` reads each named package's version from the official
repositories for every published architecture the package supports and compares
it to `rebuilt_against`. Records are kept per architecture because Arch and
Arch Linux ARM can carry different dependency versions. pkgrel is bumped once
when any recorded version moves; that one source revision is then rebuilt by
each architecture's normal queue.

The bump is the point of the command, and it has to land in git rather than in the builder. A rebuild that reuses the published version string produces a package pacman will never offer anyone, so merely unlocking the build gate would ship nothing. Bumping pkgrel needs no other change: `bin/check-versions` and the builder both already rebuild when pkgrel moves.

For an AUR-synced package the bump is expressed as the dotted Omarchy pkgrel suffix in the metadata as well as in the PKGBUILD, because the next AUR sync replaces the PKGBUILD wholesale and would otherwise drop it.

The bumped version is checked against the published one as well as the checked-in one, and refused when pacman would not order it higher. The checked-in version is not the floor; what a user already has is, and a checkout that has fallen behind the repository can otherwise be bumped to something that loses to the package it means to replace. That check is skipped with a warning when the published database cannot be read.

x86_64 versions are read from the local pacman database, so the workflow runs
in an Arch container pointed at `mirror.omarchy.org`, the same mirror as the
x86_64 builder. aarch64 versions are read directly from the live Arch Linux ARM
repository database, which is also what the ARM builder uses. Testing and
staging repositories do not count. A legacy flat `rebuilt_against` record is
read as x86_64 and is migrated naturally the next time a rebuild is needed.

### Other

```bash
bin/repo advance --from rc --to stable            # Ship the tested rc channel to stable
bin/repo advance --from edge --to rc              # Open a train: carry edge forward into rc
bin/repo advance --from edge --to rc --package x  # Deliberate single-package advance
bin/repo advance --from rc --to stable --dry-run  # Preview without changing files
bin/repo bootstrap-rc                             # One-time initial rc seed from stable
bin/repo timers                      # Timer schedule, last runs, queues, backoff, lock
bin/omarchy-release                  # Release front door (start / pick / rc / ship)
bin/repo list                        # List package metadata
bin/repo deploy                      # Build locally, then publish from the host
bin/repo push                        # Upload local builds to the host and publish
bin/add-package <package>            # Add an AUR/local package with metadata
bin/package-worktree <package>       # Create upstream/patched/current scratch workspace
bin/repo remove <package>            # Remove package
bin/sync-upstream                    # Update packages that track a vendor release feed
bin/sync-rebuilds                    # Bump pkgrel for packages whose dependencies moved
bin/clean-docker                     # Clear Docker images/cache (forces fresh rebuild)
```

### Package Metadata Tools

```bash
bin/add-package yay                  # Add AUR package, create metadata, sync from AUR
bin/add-package spotify --fast       # Add package to the fast release ring
bin/add-package foo --no-sync        # Sync once, then mark AUR sync disabled
bin/add-package my-package --local   # Create local package metadata

bin/repo list                        # Table view of source package metadata
bin/repo list --json                 # Agent/script-friendly JSON
bin/repo list --repo --mirror stable # List packages in a published repo database

bin/package-worktree v4l2-relayd     # Create upstream/patched/current scratch workspace
```

## Cutting an Omarchy Release

The `omarchy` and `omarchy-settings` packages are released as a pair, always
built from the same upstream commit of basecamp/omarchy.

**Use `bin/omarchy-release`** (see [Cutting an Omarchy release](#cutting-an-omarchy-release)
in Quick Start) — it drives the whole train across all four repositories and
calls the pin engine below for you.

`bin/omarchy-pkgs` is that engine, available directly for one-off pins and
debugging. It rewrites both PKGBUILDs in lockstep (same `_tag`/`_commit`/
`pkgver`/`sha256sums`), validates ordering with `vercmp`, commits, and pushes
the current branch. Driven by `omarchy-release` it pins to the release branch
on the `rc` branch and orders against the rc channel; invoked directly it
targets the current branch and edge.

```bash
bin/omarchy-pkgs release v4.0.0          # Final release from the upstream v4.0.0 tag
bin/omarchy-pkgs release rc v4.0.0       # Newest upstream v4.0.0-rcN tag -> 4.0.0rcN
bin/omarchy-pkgs release beta v4.0.0     # Same for beta (alpha also supported)
bin/omarchy-pkgs release latest          # Newest upstream tag, rc/beta included (prompts)
bin/omarchy-pkgs release rc              # Untagged RC from the quattro tip, auto-numbered
bin/omarchy-pkgs release --commit abc123 --base 4.1.0   # Untagged RC from a commit
bin/omarchy-pkgs release ... --dry-run   # Show the plan; write nothing
bin/omarchy-pkgs release ... --no-push   # Full flow, local commit only (testing)
bin/omarchy-pkgs self-test               # Version normalization + ordering tests
```

### Versioning rules

- Finals are `X.Y.Z`; pre-releases are `X.Y.ZalphaN` / `X.Y.ZbetaN` /
  `X.Y.ZrcN` in the **attached** form only. pacman's vercmp orders
  `4.0.0alpha1 < 4.0.0beta1 < 4.0.0rc1 < 4.0.0`, but separator forms
  (`4.0.0.rc1`, `4.0.0_rc1`) sort **after** `4.0.0` and would strand users on
  the pre-release — the tooling normalizes upstream tags (`v4.0.0-rc1`,
  `v4.0.0-rc.1`, ...) to the attached form and refuses anything it cannot
  normalize. Upstream tags are cut on the quattro branch.
- `pkgrel` resets to 1 on every version change. Bump `pkgrel` by hand only to
  repackage the same source.
- `epoch` is never set by tooling. It is sticky forever; adding one is a
  human decision of last resort.

### Where releases land

- **RCs build for the rc channel.** RC testers and RC ISO installs run the real
  `omarchy` package against the package set stable users will actually get.
  Stable never sees an rc version; rc testers upgrade rc1 → rc2 → final
  naturally.
- **Finals build into rc, then the whole channel promotes.** After testing, the
  ship step promotes the exact tested artifacts (packages and signatures)
  forward:

```bash
bin/repo advance --from rc --to stable
```

Neither package is on the `fast` ring, and `bin/omarchy-pkgs` never touches
stable — promotion is always this explicit step.

### Build trigger and the build host

Release commands run from anywhere. `bin/repo` is a **remote control**: with a
repository host configured, every command that operates on the published tree
(`release`, `build`, `sign`, `promote`, `update`, `clean`, `advance`,
`bootstrap-rc`, `remove`, `sync`, `migrate`) executes ON the host over ssh —
the exact same code, run where the tree lives, so ssh'ing in and running the
same commands by hand behaves identically. Pass `--local` to force execution
on the current machine. `list`, `push`, `deploy`, and `setup` never forward
(`push`/`deploy` exist precisely to move local builds *to* the host).

Without a configured host, commands run locally — which on the build host
itself (no `.repo-host` there) is exactly right, and elsewhere the exact
commands to run are printed by the orchestrator, with the 5-minute
auto-release timer as the backstop.

The host setting is any destination `ssh` accepts, resolved in this order:

1. `--host <dest>` on the command
2. `OMARCHY_REPO_HOST` environment variable
3. the git-ignored `.repo-host` file (one line; `#` comments allowed)

The server layout lives under `/root`, so the value is `root@<ip>`,
`root@<hostname>`, or — nicest — a `Host` alias from `~/.ssh/config` that
carries the user, key, and port:

```
# .repo-host
root@pkgs.example.com
```

All connections are plain ssh; nothing else is used to reach the host.

**How "this machine is the build host" is detected — and its one caveat.**
The marker is the published database living in this checkout
(`pkgs.omarchy.org/<channel>/<arch>/omarchy.db*`), the same convention the
rest of `bin/` uses. A workstation that once ran a full local
`bin/repo release` carries that marker too and would infer it is the host.
An explicitly configured destination always outranks the inference — `--host`,
`OMARCHY_REPO_HOST`, and `.repo-host` are checked first, and only when none is
set does local detection apply. So if a machine ever misidentifies itself,
writing the real host into `.repo-host` is the fix.

## Directory Structure

```
omarchy-pkgs/
├── pkgbuilds/                  # Source PKGBUILDs
│   └── package-name/
│       ├── PKGBUILD
│       └── .omarchy/
│           ├── package.json    # Source/sync/release metadata
│           ├── patches/        # Omarchy patches reapplied after AUR sync
│           ├── post-sync.sh    # Optional dynamic post-sync customization hook
│           └── upstream.sh     # Optional vendor release feed hook (non-AUR packages)
├── build/
├── build-output/               # Unsigned packages (temporary)
│   ├── edge/                   # (rc/ and stable/ alongside, each x86_64 + aarch64)
│   ├── rc/
│   └── stable/
├── pkgs.omarchy.org/           # Signed packages (production)
│   ├── .release.lock           # Host-wide lock: one channel mutation at a time
│   ├── edge/                   # Each channel: x86_64/ and aarch64/
│   ├── rc/
│   └── stable/
└── bin/                        # CLI tools (on host)
```

## Package Metadata

Each source package has Omarchy metadata at `pkgbuilds/<package>/.omarchy/package.json`.

Minimal examples:

```json
{ "source": "aur" }
```

```json
{ "source": "aur", "sync": false }
```

```json
{ "source": "aur", "release_ring": "fast" }
```

```json
{ "source": "local" }
```

```json
{ "source": "local", "skip_build": true }
```

```json
{ "source": "aur", "pkgrel": { "suffix": 1 } }
```

Fields:

- `source`: `aur` or `local`. A `local` package can still follow an upstream release, either declaratively via `upstream` or with an `.omarchy/upstream.sh` hook.
- `upstream`: optional for `local` packages following GitHub releases, git tags, npm dist-tags, or a Debian `Packages` index. GitHub architecture assets may be a string or an ordered array, and can be combined with disjoint versioned `sources` — see [Sync Upstream Releases](#sync-upstream-releases). Mutually exclusive with `.omarchy/upstream.sh`.
- `min_release_age`: optional quarantine for upstream releases (`"24h"`, `"2d"`, or bare seconds). The newest release older than the window ships; anything younger waits, and a release whose age cannot be proven fails the sync. Bypass deliberately with `BYPASS_MIN_RELEASE_AGE=1 bin/sync-upstream <package>`.
- `sync`: optional for AUR packages; defaults to `true`. Set `false` for AUR-origin packages that Omarchy maintains manually.
- `aur`: optional AUR package name when it differs from the local package directory, usually for split packages.
- `release_ring`: optional. `fast` means the package is built directly for stable as well as edge, with the artifacts replicated into rc for parity. Packages without a ring build in edge and reach stable through the pipeline (`bin/repo advance`).
- `channels`: optional array bounding where the package may be built (`edge`, `rc`, `stable`). Without the key a package is a member of every channel and follows the default build rules above; `bin/repo advance` refuses to carry a package anywhere it isn't a member.
- `pinned`: optional boolean. A pinned package's version is set per release by `omarchy-release` on the `rc` branch, so it is never built for stable (promotion only) and is built for rc only from that branch's worktree (`OMARCHY_RC_PINS=1`). Used by `omarchy` and `omarchy-settings`.
- `skip_build`: optional boolean; defaults to `false`. Set `true` to exclude a package from scheduled version checks and unscoped builds. The package can still be built explicitly with `bin/repo release --package <name>`.
- `pkgrel`: optional Omarchy pkgrel suffix for a version-pinned rebuild bump. This emits `<aur pkgrel>.<suffix>` instead of replacing AUR's pkgrel. `offset` can be used only when preserving monotonic upgrades from old absolute pkgrel bumps. The metadata is removed automatically when AUR sync changes `pkgver`; the current package version is read from the checked-in PKGBUILD, so the version is not duplicated in JSON.
- `rebuild_on`: optional array of package names this package links against closely enough that it must be rebuilt when they change, independent of its own source. Read by `bin/sync-rebuilds`.
- `rebuilt_against`: written by `bin/sync-rebuilds`. Maps each published architecture to the versions of its `rebuild_on` packages that the current pkgrel was bumped for.
- `upstream_commit`: set by `bin/sync-aur` for AUR packages. Used by `bin/package-worktree` to recreate the exact raw AUR package that Omarchy last synced.

### Build Matrix

- **Edge unscoped builds** (`--mirror edge`): packages in `pkgbuilds/*` unless `"skip_build": true` or `channels` excludes edge
- **Rc unscoped builds** (`--mirror rc`): `"release_ring": "fast"` packages, built natively in the rc image. The pinned release pair joins them only when `OMARCHY_RC_PINS=1` (the `rc` branch worktree, set by `omarchy-release rc`)
- **Stable unscoped builds** (`--mirror stable`): packages with `"release_ring": "fast"` unless `"skip_build": true`
- **Explicit builds** (`--package <name>`): the selected package, including packages with `"skip_build": true`, subject to mirror eligibility
- **Channel moves** (`bin/repo advance`): copies current packages + signatures forward through edge → rc → stable, never rewriting a published filename

## Adding Packages

### From AUR

```bash
bin/add-package package-name
bin/repo release --package package-name
```

### From AUR, fast release ring

```bash
bin/add-package package-name --fast
bin/repo release --package package-name
bin/repo release --mirror stable --package package-name
```

### AUR-origin, manually maintained by Omarchy

```bash
bin/add-package package-name --no-sync
```

### Local Customizations for AUR Packages

For static changes, create `pkgbuilds/package-name/.omarchy/patches/*.patch` to maintain modifications across AUR syncs.

The recommended workflow is to use a scratch workspace:

```bash
bin/package-worktree package-name --dir /tmp/package-name-worktree
```

This creates:

```text
upstream/  # raw AUR package at upstream_commit
patched/   # AUR + existing Omarchy .omarchy customizations
current/   # current checked-in package directory
```

Patch-authoring flow:

```bash
# 1. Make the intended change in pkgbuilds/package-name/

# 2. Recreate the scratch workspace
bin/package-worktree package-name --dir /tmp/package-name-worktree

# 3. Inspect drift from patched -> current
# For multi-file changes, inspect this and split into focused patches.
diff -ruN /tmp/package-name-worktree/patched /tmp/package-name-worktree/current

# For a single PKGBUILD change, write a patch like this:
mkdir -p pkgbuilds/package-name/.omarchy/patches
(
  cd /tmp/package-name-worktree/patched
  diff -u --label a/PKGBUILD --label b/PKGBUILD \
    PKGBUILD /tmp/package-name-worktree/current/PKGBUILD || true
) > pkgbuilds/package-name/.omarchy/patches/my-fix.patch

# 4. Verify the package is reproducible from AUR + .omarchy
bin/sync-aur package-name
bin/package-worktree package-name --dir /tmp/package-name-check
diff -ruN /tmp/package-name-check/patched /tmp/package-name-check/current
```

For dynamic changes that depend on the current upstream version, add `pkgbuilds/package-name/.omarchy/post-sync.sh`. The hook runs after the AUR package is copied into a temporary worktree and before the Omarchy pkgrel suffix is applied. After patches/hooks/metadata pkgrel overrides, `bin/sync-aur` removes AUR-only `.SRCINFO` and `.gitignore` files before writing the package back.

### Custom Package

```bash
bin/add-package my-package --local --scaffold
# Fill in PKGBUILD and package files
bin/repo release --package my-package
```

## Architecture-Specific Notes

### x86_64
- Native builds (fast)
- Mirrors: mirror.omarchy.org, rackspace, pkgbuild.com

### aarch64
- Built on the repository host like x86_64; under QEMU when the host is x86_64
- On an ARM host, package builds and the signing/database utility containers
  run natively; only an explicitly requested x86_64 package build is emulated
- Uses Arch Linux ARM repositories through the same HTTPS mirror for every
  channel (Arch Linux ARM publishes no dated snapshots to pin a channel's base)
- Additional repos: `[alarm]`, `[aur]`
- Same workflow, just add `--arch aarch64`; the scheduled pipeline runs it
  automatically once `aarch64` is in `PUBLISHED_ARCHES`
- Packages whose `arch=()` lacks `aarch64` are skipped, not failed

### Building for Both Architectures

```bash
# Build x86_64
bin/repo release --package myapp

# Build aarch64
bin/repo release --arch aarch64 --package myapp

# Sync both
bin/repo sync
bin/repo sync --arch aarch64
```

## Dependency Resolution

The build system automatically handles inter-package dependencies:

1. Parses `depends=()` and `makedepends=()` from PKGBUILDs
2. Builds in correct order
3. Makes newly-built packages available via temporary `[omarchy-build]` repo

Example: If `aether` depends on `hyprshade`, `hyprshade` is built first.

## Version Management

Packages are only rebuilt if:
- PKGBUILD version is newer than repository version
- Package doesn't exist in production

Neither notices a package that has to be rebuilt because something underneath it changed. That case is handled by turning it into a version change: `bin/sync-rebuilds` bumps pkgrel when a dependency named in `rebuild_on` moves.

## Automated Releases

The repository includes GitHub workflows and systemd services for automated releases.

### How It Works

#### GitHub Workflows

1. **sync-aur.yml** (Every 6 hours): Syncs AUR packages according to `.omarchy/package.json` and opens a PR when changes are found.
2. **sync-upstream.yml** (Every 6 hours): Runs `.omarchy/upstream.sh` for packages that track a vendor release feed and opens a PR when a newer version is out.
3. **sync-rebuilds.yml** (Every 6 hours): Bumps pkgrel for packages whose `rebuild_on` dependencies have moved in the official repositories and opens a PR.

#### Systemd Services

All four units run **every 5 minutes**, staggered by a minute each, so a push
reaches the mirror in minutes rather than hours:

1. **check-versions** (`*:0/5`): Pulls latest from git, compares PKGBUILD versions to published versions for every published architecture, creates one state file per channel and architecture if builds are needed
2. **auto-release-edge** (`*:1/5`): For each published architecture with a state file, builds all edge packages that need updates
3. **auto-release-rc** (`*:2/5`): Builds fast-ring packages for rc, from the main checkout like the other two — natively in the rc image, not copied from another channel. The pinned release pair is built separately by `omarchy-release rc` in the `rc` branch worktree
4. **auto-release-stable** (`*:3/5`): If a state file exists, builds `release_ring=fast` packages for stable and replicates them to rc

That cadence is only safe because of three guards:

- **No overlap.** Every channel-mutating run takes a host-wide lock
  (`pkgs.omarchy.org/.release.lock`). Scheduled runs take it
  **non-blocking**: if a build is already going, the tick exits immediately
  instead of queuing. Waiting would stack one stalled process per tick behind
  a long build and stampede when it finished. Manual commands still wait, as
  an operator expects. `check-versions` takes it too — its `git pull` would
  otherwise swap PKGBUILDs out from under a running build.
- **Backoff on failure.** A failed release records the attempt in
  `.build-failed-<channel>-<arch>` and backs off exponentially — 10m, 20m, 40m, up to
  a 6h ceiling — instead of rebuilding the same broken tree every 5 minutes.
  **Any new commit clears the backoff immediately**, since a push is the most
  likely fix. Clear it by hand with
  `rm /root/.state/.build-failed-<channel>-<arch>`.
- **Quiet when idle.** With nothing queued a tick exits without output, so the
  journal shows the runs that mattered rather than 288 no-ops a day.

`bin/repo timers` reports all of this: schedules, last results, what is
queued, what is failing and when it will retry, and whether the lock is held.

### Build reports

Every release run reports to Basecamp Campfire — not just failures, so a push
can be followed all the way to the mirror without watching the host:

| Event | Message |
|---|---|
| 🔨 Started | channel, arch, host, the commit being built, and which packages are queued |
| ✅ Published | the packages and versions that went out, duration, and the channel URL |
| 📦 Promoted | what `advance` moved between channels (including the rc bootstrap and fast-ring replication) |
| 📦 Nothing to publish | a queued run built nothing — see below |
| 🔴 Failed | which step failed, the commit, and the last 25 log lines |

Reports are tied to release *runs*, not timer ticks: a tick with nothing
queued exits silently, so a quiet day is a quiet chat. That is what makes the
"nothing to publish" report meaningful rather than routine — a release only
runs when the version check queued work, so building nothing means the check
and the builder disagree about what is out of date. It names the packages that
were queued but not built, which is where to start looking.

By default everything posts to `BASECAMP_CHATBOT_URL`, the same chat the
AUR/upstream sync workflows use — one variable, nothing extra to configure.

If release traffic starts drowning that chat, give it its own: create a second
Basecamp chat, add a chatbot integration to it, and export its lines URL
alongside the existing one in `/root/.omarchy/build-credentials`:

```bash
export OMARCHY_RELEASE_CHATBOT_URL="https://3.basecamp.com/<account>/integrations/<key>/buckets/<project>/chats/<chat>/lines"
```

Release reports then go there while the sync workflows keep posting to
`BASECAMP_CHATBOT_URL`. With neither set, reports are silently skipped.
`bin/setup` reports which of the three cases applies.

Check on all of it with `bin/repo timers` — schedule, each unit's last run and
whether it succeeded, what is queued, whether a release is running right now,
and any failed units. Like the other host commands it forwards over ssh, so
the build box's state is one command away from any machine:

```bash
bin/repo timers           # runs on the repository host when one is configured
bin/repo timers --local   # inspect this machine instead
```

State files are stored in `/root/.state/`:
- `.sync-needed-<channel>-<arch>` — the packages queued for that channel and
  architecture, one per line; the release run reads them to name what it is
  building
- `.build-failed-<channel>-<arch>` — consecutive failure count, timestamp, and
  the commit it failed on (drives the backoff; removing it forces a retry)

Legacy files without the architecture suffix are consumed once as x86_64
state, so upgrading the host does not lose an in-flight build.

### Schedule (America/New_York)

| Minute of every hour | Action |
|------|--------|
| :00, :05, :10, … | check-versions (git pull + creates state files) |
| :01, :06, :11, … | auto-release-edge |
| :02, :07, :12, … | auto-release-rc |
| :03, :08, :13, … | auto-release-stable |

Each unit is a no-op unless its channel has queued work, another run holds the
lock, or the channel is in failure backoff.

### Installation

```bash
ssh root@<host> 'cd /root/omarchy-pkgs && bin/setup'
```

`bin/setup` installs the dependencies, ensures Docker is running, creates the
state directory, and installs and enables the release timers. It works on
Debian/Ubuntu and on Arch, and is idempotent, so run it again whenever a
dependency is added.

The host does not need to be Arch: makepkg, repo-add and package signing all
run inside containers, so it needs only Docker, rclone, bsdtar, jq, git and
rsync. Docker is left alone when it already works, rather than replacing a
working installation from Docker's own repository with the distribution's.

```bash
bin/repo setup --check         # Report what is missing, change nothing
bin/repo setup --skip-timers   # Prepare the host without the release timers
```

Signing credentials (`/root/.omarchy/build-credentials`) and the rclone remote
hold secrets, so setup reports on them rather than creating them.

### Management

```bash
# Everything at a glance: schedules, last runs, queues, backoff, lock
bin/repo timers                     # forwards to the host when one is configured

# Manual trigger (edge, rc, stable)
systemctl start omarchy-check-versions.service
systemctl start omarchy-auto-release-edge.service

# View logs
journalctl -u omarchy-auto-release-edge.service -n 50

# Clear a channel stuck in failure backoff (a new commit also clears it)
rm /root/.state/.build-failed-edge

# Release lock left behind by a killed run (bin/repo timers shows if it is live)
rm /root/omarchy-pkgs/pkgs.omarchy.org/.release.lock
```

The main checkout is pulled by `check-versions` on its 5-minute tick, so the
host stays current on whatever branch it has checked out — it must be `master`.
