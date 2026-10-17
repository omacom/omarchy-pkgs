# The repository host (abandoned)

**This pipeline is abandoned.** Packages are built and published by GitHub
workflows: see the [README](../README.md). Don't follow this page to publish
anything.

The package pipeline used to run on one machine that built, signed and
published every channel on a timer. This page is kept as the reference for
the tooling that was written for it and is still in the tree: `bin/repo`, the
units in `systemd/`, and the host side of the release train
([releases.md](releases.md)).

**That tooling writes to the same bucket as CI.** If you run any of it
(`release`, `sync`, `promote`, `push`, `deploy`, `advance`, `remove`), these
rules apply:

- Do not run `bin/repo release`, `sync`, `push` or `deploy` for a package CI
  publishes. Merge a PR, or dispatch `publish.yml`, instead.
- Keep the `omarchy-auto-release-*` and `omarchy-check-versions` timers
  disabled while CI publishes the same channels. Two writers on one channel
  database overwrite each other.
- Never pass `--prune` to `bin/repo sync`. The host's tree does not hold what
  CI published, and `--prune` deletes remote files the local tree lacks.
- Never rebuild a version that is already published. Bump `pkgrel`.

## Setting up a host

> Abandoned. Kept as reference for the tooling; don't follow it to publish.

### aarch64 under emulation

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

## Published architectures

> Abandoned. Kept as reference for the tooling; don't follow it to publish.

`helpers/paths.sh` names the architectures the host's scheduled pipeline and
release train work on. CI does not read it:

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
through. Rerunning the same advance after a failed remote sync completes it
safely.

Adding an architecture to the scheduled pipeline is therefore one checked-in
change to that list: the next `check-versions` tick queues everything the new
architecture lacks, and the next `auto-release` tick starts building it. CI
does not read this list: it builds the architectures in `CI_ARCHES`, both by
default. For a one-off run, override it directly:

```bash
OMARCHY_ARCHES=x86_64 bin/check-versions
OMARCHY_ARCHES=aarch64 bin/check-versions
OMARCHY_ARCHES="x86_64 aarch64" bin/check-versions
```

The builder image bootstraps
`omarchy-keyring` from the x86_64 tree for every architecture, so the first
build of a new architecture does not depend on a repository that only it can
create.

## Release in one command

> Abandoned. Kept as reference for the tooling; don't follow it to publish.

The release command is smart and **incremental** - it only builds packages that have changed or are missing. You generally don't need to specify a package manually unless you are debugging a specific failure.

When a package fails, a completed build run still signs and publishes the packages
that succeeded. Failed packages and their blocked dependents remain queued with
failure backoff; retries compare against the updated repository and skip the
published versions. Only artifacts recorded by fully completed package builds
are eligible for a partial release. An interrupted build, a failed publication
step, or an incomplete pair using deferred runtime dependencies still stops the
release. Reports distinguish partial publication from complete success.

```bash
# Build changed/new packages, sign, promote, clean, update, and sync
bin/repo release

# Stable Mirror
bin/repo release --mirror stable

# ARM64
bin/repo release --arch aarch64

# Build one package (still skipped when its version is already published)
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

## Building Heavy Packages Locally

> Abandoned. Kept as reference for the tooling; don't follow it to publish.

Large packages build faster on a local machine than on the server. Build them
here, then hand the artifacts to the repository host, which signs and publishes
them:

```bash
bin/repo deploy --package nvidia-580xx-utils   # Build here, publish from the host
```

`deploy` is `build` followed by `push`. The two steps are also available
separately when a build needs inspecting before it ships:

```bash
bin/build --package nvidia-580xx-utils         # Build on the fast machine
bin/repo push --package nvidia-580xx-utils     # Upload + publish on the host
```

`push` uploads to the host's `build-output/`, verifies checksums, and runs
`bin/upload-prebuilt` there. Do not publish from a local checkout instead: a
local machine holds neither the complete repository nor a signing key.

**Name the package.** `build` plans against the local repository database, or
against the public channel's when there is none. `deploy` refuses to run
unscoped when the local database is missing. Unscoped builds belong on
the repository host, where `bin/repo release` does the same job against a real
database.

Every other `bin/repo` command — `sign`, `promote`, `update`, `clean`,
`advance`, `remove`, `sync`, `release` — works on the published tree. Run them
from anywhere: with a repository host configured `bin/repo` forwards them over
ssh to run there (see [Build trigger and the build host](#build-trigger-and-the-build-host)),
and `--local` forces execution on the current machine. `bin/repo build`
forwards too; call `bin/build` directly, or pass `--local`, to build on this
machine. `push` and `deploy` always run locally.

## Commands

> Abandoned. Kept as reference for the tooling; don't follow it to publish.

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

**Output**: Unsigned `.pkg.tar.zst` in `build-output/`. Only builds packages whose version differs from what the repository holds.

Use `--dry-run` to show the build plan without running `makepkg`.

### Sign

```bash
bin/repo sign
```

Reads the GPG key and passphrase from the environment and signs all packages in `build-output/`. Supports `--arch` and `--mirror`.

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
```

Syncs package repositories to the remote server using rclone based on the configured mirror and architecture.

**Uploads are additive.** A local tree is not authoritative about what belongs on
the remote — `pkgs.omarchy.org/` is gitignored, and packages built on another
machine exist only there — so sync never deletes by default. To take a package
out of the channels, use the `unpublish.yml` workflow.

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

Publishing happens on the host rather than locally for two reasons: the host
has a GPG signing key (CI has its own copy in the `publish` environment), and
it holds the repository tree that its database and sync are built from. Local
machines therefore need no secrets.

The host comes from `--host`, `$OMARCHY_REPO_HOST`, then `.repo-host`. The
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

### Other host commands

```bash
bin/repo advance --from rc --to stable            # Ship the tested rc channel to stable
bin/repo advance --from edge --to rc              # Open a train: carry edge forward into rc
bin/repo advance --from edge --to rc --package x  # Deliberate single-package advance
bin/repo advance --from rc --to stable --dry-run  # Preview without changing files
bin/repo bootstrap-rc                             # One-time initial rc seed from stable
bin/repo timers                      # Timer schedule, last runs, queues, backoff, lock
bin/repo list                        # List package metadata
bin/repo deploy                      # Build locally, then publish from the host
bin/repo push                        # Upload local builds to the host and publish
bin/repo remove <package>            # Remove package (host workflow; CI uses unpublish.yml)
bin/clean-docker                     # Clear Docker images/cache (forces fresh rebuild)
```

## Build trigger and the build host

> Abandoned. Kept as reference for the tooling; don't follow it to publish.

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

1. `--host <dest>`, for `push`, `deploy` and `bin/omarchy-release`
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

> Abandoned. Kept as reference for the tooling; don't follow it to publish.

```
omarchy-pkgs/
├── pkgbuilds/                  # Source PKGBUILDs
│   └── package-name/
│       ├── PKGBUILD
│       └── .omarchy/
│           ├── package.json    # Source/sync/release metadata
│           └── upstream.sh     # Optional custom vendor release feed hook
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

## Architecture-Specific Notes

> Abandoned. Kept as reference for the tooling; don't follow it to publish.

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

## Version Management

> Abandoned. Kept as reference for the tooling; don't follow it to publish.

Packages are only rebuilt if:
- PKGBUILD version differs from the repository version
- Package doesn't exist in production

A package that has to be rebuilt because something underneath it changed is handled by turning that into a version change: `bin/sync-rebuilds` bumps pkgrel when a dependency named in `rebuild_on` moves.

## Scheduled releases on the host

> Abandoned. Kept as reference for the tooling; don't follow it to publish.

Four systemd units in `systemd/` drive unattended releases from the host.

All four units run **every 5 minutes**, staggered by a minute each, so a push
reaches the mirror in minutes rather than hours:

1. **check-versions** (`*:0/5`): Pulls latest from git, compares PKGBUILD versions to published versions for every published architecture, creates one state file per channel and architecture if builds are needed
2. **auto-release-edge** (`*:1/5`): For each published architecture with a state file, builds all edge packages that need updates
3. **auto-release-rc** (`*:2/5`): Builds fast-ring packages for rc, from the main checkout like the other two — natively in the rc image, not copied from another channel. The pinned release pair is built separately by `omarchy-release rc` in the `rc` branch worktree
4. **auto-release-stable** (`*:3/5`): If a state file exists, builds `release_ring=fast` packages for stable

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

## Build reports

> Abandoned. Kept as reference for the tooling; don't follow it to publish.

Every release run reports to Basecamp Campfire — not just failures, so a push
can be followed all the way to the mirror without watching the host:

| Event | Message |
|---|---|
| 🔨 Started | channel, arch, host, the commit being built, and which packages are queued |
| ✅ Published | the packages and versions that went out, duration, and the channel URL |
| 📦 Promoted | what `advance` moved between channels (including the rc bootstrap) |
| 📦 Nothing to publish | a queued run built nothing — see below |
| 🔴 Failed | which step failed, the commit, and the last 25 log lines |

Reports are tied to release *runs*, not timer ticks: a tick with nothing
queued exits silently, so a quiet day is a quiet chat. That is what makes the
"nothing to publish" report meaningful rather than routine — a release only
runs when the version check queued work, so building nothing means the check
and the builder disagree about what is out of date. It names the packages that
were queued but not built, which is where to start looking.

By default everything posts to `BASECAMP_CHATBOT_URL`, the same chat the
sync workflows use — one variable, nothing extra to configure.

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

## Schedule (America/New_York)

> Abandoned. Kept as reference for the tooling; don't follow it to publish.

| Minute of every hour | Action |
|------|--------|
| :00, :05, :10, … | check-versions (git pull + creates state files) |
| :01, :06, :11, … | auto-release-edge |
| :02, :07, :12, … | auto-release-rc |
| :03, :08, :13, … | auto-release-stable |

Each release unit is a no-op when its channel has nothing queued, another run
holds the lock, or the channel is in failure backoff.

## Installation

> Abandoned. Kept as reference for the tooling; don't follow it to publish.

```bash
ssh root@<host> 'cd /root/omarchy-pkgs && bin/setup --skip-timers'
```

`bin/setup` installs the dependencies, ensures Docker is running and creates
the state directory. Without `--skip-timers` it also installs and enables the
release timers, which must stay off while CI publishes. It works on
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

## Management

> Abandoned. Kept as reference for the tooling; don't follow it to publish.

```bash
# Everything at a glance: schedules, last runs, queues, backoff, lock
bin/repo timers                     # forwards to the host when one is configured

# Manual trigger (edge, rc, stable)
systemctl start omarchy-check-versions.service
systemctl start omarchy-auto-release-edge.service

# View logs
journalctl -u omarchy-auto-release-edge.service -n 50

# Clear a channel stuck in failure backoff (a new commit also clears it)
rm /root/.state/.build-failed-edge-x86_64

# Release lock left behind by a killed run (bin/repo timers shows if it is live)
rm /root/omarchy-pkgs/pkgs.omarchy.org/.release.lock
```

With the timers enabled, `check-versions` pulls the main checkout on its
5-minute tick. With them disabled, nothing does: `bin/repo` pulls before a
command it forwards, and a command run on the host itself needs a `git pull`
first. The checkout must be on `master`.
