# Omarchy Package Repository

Recipes and tooling for the packages Omarchy ships from
`https://pkgs.omarchy.org/<channel>/<arch>`.

- **Channels:** `edge` → `rc` → `stable`. Packages only move forward.
- **Architectures:** `x86_64` and `aarch64`.
- **Recipes:** one directory per package in `pkgbuilds/<package>/`, with a
  `PKGBUILD` and `.omarchy/package.json`.

## Contribute a package

Everything a package PR needs is in `pkgbuilds/<package>/`. No secrets or
access are required. To work locally you need:

- `git`, `bash`, `jq`, `curl` and a `tar` that reads zstd
- Docker or Podman that your user can run, to build. With Docker, a build
  calls `sudo` to fix the ownership of its output.
- on Arch, to check an upstream declaration: Python 3.11+, `vercmp`, `bsdtar`

Questions and problems: open an issue on this repository.

### Add a new package

1. Fork the repository and branch from `master`.
2. Create the recipe:

   ```bash
   bin/add-package my-package --local --scaffold   # Starter PKGBUILD and metadata
   bin/add-package my-package --source aur         # Or import an AUR recipe once
   ```

   An imported recipe is Omarchy's from then on; there is no AUR sync.
3. Write `pkgbuilds/my-package/PKGBUILD` to Arch packaging standards.
   - List every architecture it supports in `arch=()`: `x86_64`, `aarch64`,
     or `any`. CI builds each one.
   - Pin every git source with `#commit=<sha>` or `#tag=<tag>`. An unpinned
     source is rejected; `tests/pinned-sources.sh` checks it locally.
   - Fill the checksums: run `updpkgsums` (from `pacman-contrib`) in the
     package directory. For a git source it leaves a clone of the source
     there; delete it before committing.
4. Declare where new releases come from in
   `pkgbuilds/my-package/.omarchy/package.json`, so updates arrive without
   another PR. See [docs/upstream-sources.md](docs/upstream-sources.md).

   ```json
   {
     "source": "local",
     "upstream": { "watch": { "github": "owner/project", "pattern": "v(?P<version>[0-9]+(?:\\.[0-9]+)*)" } }
   }
   ```

   Use this `watch` form for a new package. The pattern must match the whole
   tag, so drop the `v` for a project that tags `1.2.3`. A `github` watch
   reads GitHub Releases; for a project that only pushes tags, watch the tags:

   ```json
   "upstream": { "watch": { "git_tags": "https://github.com/owner/project.git", "pattern": "(?P<version>[0-9]+(?:\\.[0-9]+)*)" } }
   ```

   Check that it finds the current release:

   ```bash
   python helpers/upstream-watch.py check pkgbuilds/my-package
   ```

   A working watch on a current recipe prints
   `{"status": "skipped", ..., "reason": "already current"}`.

   If the package should not be updated automatically, set `"sync": false`
   and say why in the PR.
5. Build it:

   ```bash
   bin/build --package my-package --dry-run       # Show the plan
   bin/build --package my-package                 # Build for x86_64
   bin/build --package my-package --arch aarch64  # Emulated on an x86_64 machine; slow
   ```

   `--dry-run` only shows the plan; it does not validate the recipe. The
   package lands unsigned in `build-output/edge/<arch>/`. Install it with
   `pacman -U` to try it. CI builds aarch64 natively, so a local aarch64
   build is optional.
6. Open a PR against `master` with one package in it. Say what the package
   is, and how you tested it.

### Update or fix an existing package

- **New upstream version:** for a package with an `upstream` declaration, a
  bot proposes the update on its next scheduled run, or later if the package
  sets `min_release_age`; you don't need to. Otherwise set `pkgver`, run
  `updpkgsums`, and reset `pkgrel` to 1.
- **Packaging change at the same version:** bump `pkgrel`. A PR that changes
  a recipe without moving its version builds nothing and ships nothing; when
  the `PKGBUILD` itself changed, the PR's build check carries a "Change will
  not ship" warning. (A `-git` package whose version carries the commit hash
  is also rebuilt when its pinned commit changes.)
- Never set `epoch` without agreeing it in the PR first; it is permanent.

### What happens to your PR

1. **It waits for build approval** unless you are a collaborator or listed
   in `.github/VOUCHED.td`. A maintainer starts the builds by labelling the
   PR `build-approved`. Until then it shows **Awaiting build approval**, or,
   for your first PR here, GitHub's own "workflows awaiting approval".
   Builds cost machines, so they run for trusted authors only.
2. **CI builds the package** for each architecture and runs the tests. The
   required checks are `result`, `self-tests` and `build-isolation`.
3. **It merges itself when green**, if it changes only package files.
4. **It is published to `edge`** within minutes of merging, and reaches
   `rc` and `stable` when those channels are next
   [promoted](#promote-a-channel). Say so in the PR if you think the
   package should reach `stable` immediately (the fast ring).

Keep a package PR to these files, or it needs a maintainer to merge it by
hand:

- anything under `pkgbuilds/`
- a new test under `tests/`, and the one line in `.github/workflows/test.yml`
  that runs it

Changes to `bin/`, `helpers/`, `build/` or the workflows go in a separate PR,
first: a PR's packages are built with `master`'s tooling, not its own.

## How a package reaches users

```
PR touching pkgbuilds/<package>/
  └─ build-pr.yml       one build per package and architecture, unsigned
merge to master
  └─ publish.yml        collect the builds, sign, add to the channel
                        databases, upload; then bring rc and stable in line
                        with edge for the fast ring
by hand, from Actions or bin/omarchy-release
  ├─ promote.yml        Promote channel: edge -> rc, rc -> stable
  └─ release-rc.yml     Build release candidate: the rc branch's pins -> rc
pkgs.omarchy.org        served from the R2 bucket omarchy-pkgs through a CDN
```

To ship a change: open a PR, wait for green, merge. Nothing else is needed.

1. **Build.** `build-pr.yml` builds every package directory the PR touches,
   once, against `edge`. x86_64 builds on an ephemeral DigitalOcean droplet
   (runner label `omarchy-builder`), aarch64 on GitHub's `ubuntu-24.04-arm`
   (aarch64 kernels on Namespace; see [the runner table](#where-a-package-is-published)).
   Each build is kept as a workflow artifact for 7 days, named
   `<package>-<arch>-<git tree hash of the package directory>`.
2. **Merge.** Branch protection requires `result`, `self-tests` and
   `build-isolation`. Don't merge around a red check.
3. **Publish.** `publish.yml` runs on every push to `master` that touches
   `pkgbuilds/**`. It finds the artifact for exactly the merged tree, signs
   it, and publishes it to every channel and architecture the package ships
   to. When no artifact exists it builds one first, in a separate job. Its
   last step copies `edge`'s file to `rc` or `stable` for any fast-ring
   package either is missing. It reports in a comment on the merged PR and
   appends to the [publish log](#read-the-publish-log).

Nothing else moves on its own: `rc` and `stable` change only when someone
[promotes](#promote-a-channel) them or [cuts a release](#releases).

A package is built once and that one file is what every channel serves.
**A published filename never changes its bytes.** To ship a different build
of the same version, bump `pkgrel`.

## Where a package is published

`bin/build-matrix` decides, from `.omarchy/package.json`:

| Package | Published on merge to |
|---|---|
| Default | `edge` |
| `"release_ring": "fast"` | `edge`, `rc` and `stable` |
| `"channels": [...]` | never outside the listed channels; the other rows still apply within them |
| `"pinned": true` (`omarchy`, `omarchy-settings`) | `edge`; `rc` only through a [release candidate](#releases), `stable` by promotion |

A package is published for each architecture in its `arch=()`. An `arch=any`
package builds once and goes into both architectures' databases.

It also decides where each build runs (`package_runner` in
`helpers/package-metadata.sh`):

| Build | Runner |
|---|---|
| x86_64 | the droplet pool |
| aarch64 | GitHub's `ubuntu-24.04-arm` (4 vCPU) |
| aarch64 kernel (`linux-*`) | `namespace-profile-arm64-linux-apple-12x32` (Linux on Apple Silicon, 12 vCPU) |

A build that has to be repeated at merge runs on the same runner.

Everything not on the fast ring reaches `rc` and `stable` by promotion: see
[Releases](#releases).

### What can be on the fast ring

A fast-ring package is still built once, against edge, and that file lands on
`rc` and `stable` straight away, ahead of the Arch snapshot it was built
against. So the fast ring is for packages whose files do not care which
snapshot they run on: vendor binaries, static Go and Rust tools, scripts,
themes and fonts. A package that needs rebuilding when a dependency moves
stays off it and reaches `rc` and `stable` with the release, together with
the libraries it was built for.

The three channels serve the same file. A merge that publishes a fast-ring
build writes it to all three, and the same run copies `edge`'s file to `rc` or
`stable` when either is behind, so moving a package onto the fast ring brings
its current build along (see [Republish a package](#republish-a-package)).

Both halves are enforced. `rebuild_on` and `"release_ring": "fast"` cannot be
combined. And after a fast-ring package builds, `build-pr.yml` runs
`bin/check-fast-ring`, which installs the package on `edge`, `rc` and `stable`
from each channel's own repositories and fails the build when:

- a dependency that edge provides cannot be satisfied on `rc` or `stable`;
- a binary needs a library or a versioned symbol (`GLIBC_2.43`, say) that
  `rc` or `stable` does not have yet (`ldd -r`). Edge is the baseline: an
  optional plugin whose library is missing on every channel is not the fast
  ring's concern;
- the package installs Python modules, or it is compiled here (its PKGBUILD
  has a `build()`) and a binary links Qt or libpython. These break on a
  dependency update without a missing symbol to show it: Qt's private API and
  plugin version check, Python's versioned module path. A vendor's binary is
  the same bytes whatever we rebuild, so for it only the library check
  applies.

On aarch64 every channel runs the same live Arch Linux ARM repositories, so
only the rules are checked there.

A package that fails the check comes off the fast ring; nothing else about it
changes.

## Maintainer tasks

### Republish a package

Use this when a publish run failed or was cancelled, or a package is missing
from a channel:

```bash
gh workflow run publish.yml -R omacom/omarchy-pkgs -f packages="<package> ..."
```

It publishes `master`'s version of each named package, reusing a build
artifact when one exists and building otherwise. With no artifact, it skips a
package that `edge` already holds at that version for that architecture; bump
`pkgrel` to publish that one again. Spell the names as the directories under
`pkgbuilds/`: an unknown name is ignored and the run still passes.

A fast-ring package `edge` already holds is not skipped everywhere: every
publish run ends by bringing `rc` and `stable` in line with `edge` for its
fast-ring packages (`bin/promote-channel --fast-ring`), copying `edge`'s file
where they are behind. Naming a fast-ring package here repairs a channel that
never got it, such as one that joined the fast ring after its last build.

For a run that failed, see [When a publish fails](#when-a-publish-fails).

### Build a package without publishing

```bash
gh workflow run build-pr.yml -R omacom/omarchy-pkgs -f packages="<package> ..."

bin/build --package <package>                  # Locally; needs Docker or Podman
bin/build --package <package> --arch aarch64   # Emulated on an x86_64 machine
bin/build --package <package> --dry-run        # Show the plan only
```

Both build only a version that `edge` does not hold yet. To build a published
version again locally, plan without the channel:

```bash
OMARCHY_PUBLISHED_REPO_URL= bin/build --package <package>
```

That also drops this repository as a source of dependencies, so it only works
for a package that depends on nothing else built here.

Local output is unsigned, in `build-output/edge/<arch>/`. Don't publish from
a local checkout.

### Retire a package

1. Delete `pkgbuilds/<package>/` in a PR and merge it.
2. Remove it from the channel databases:

   ```bash
   gh workflow run unpublish.yml -R omacom/omarchy-pkgs \
     -f packages="<pkgbase> ..." -f channels="edge rc stable"
   ```

   It removes every entry built from those pkgbases, split and `-debug`
   packages included, from both architectures. It refuses a package that
   still has a recipe on `master`. Package files stay in the bucket: nothing
   references them once the entries are gone.

### Promote a channel

Edge collects every merge; rc and stable move only when someone promotes
them. Run **Promote channel** from the Actions tab, or:

```bash
gh workflow run promote.yml -R omacom/omarchy-pkgs -f direction="edge -> rc"
gh workflow run promote.yml -R omacom/omarchy-pkgs -f direction="edge -> rc" -f dry_run=true   # plan only
gh workflow run promote.yml -R omacom/omarchy-pkgs -f direction="rc -> stable" -f packages="<pkgbase> ..."
```

For each architecture, `bin/promote-channel` moves every pkgbase the source
channel holds a newer version of, or one the destination lacks, unless its
recipe on `master` keeps it out:

| Held back | Why |
|---|---|
| `"release_ring": "fast"` | Already published to `rc` and `stable` at merge |
| `"pinned": true`, into `rc` | The release pair reaches `rc` through a release; `rc -> stable` carries it |
| `"channels"` without the destination | Never published there |
| No recipe on `master` | Retired; [unpublish it](#retire-a-package) instead |
| Destination ahead on any of its packages | Nothing moves backwards, and a pkgbase moves whole |

It copies the exact files the source serves, checks each against the source
database's SHA-256, and publishes them with `bin/publish-artifact` in batches
of about 2 GiB, inside the same lock as merges. Nothing is removed from the
destination. A re-run after a failure picks up where it stopped.

The run's summary lists what moved and what stayed back, with the reason;
the full plan is kept as the `promote-record-<run-id>` artifact for 90 days,
and a run that publishes appends to the [publish log](#read-the-publish-log)
with who ran it.

### Check that a version is live

What the recipe says, from an up-to-date checkout of `master` (`<recipe>` is
the directory name under `pkgbuilds/`), and whether a channel still lacks it:

```bash
(cd pkgbuilds/<recipe> && makepkg --printsrcinfo | grep -E '^\s*(epoch|pkgver|pkgrel) =')
bin/build --dry-run --mirror edge --package <recipe>   # "would build" lists what edge lacks
```

What each channel serves. A database lists every package as
`<name>-<version>/`:

```bash
for channel in edge rc stable; do for arch in x86_64 aarch64; do
  db=$(curl -fsSL "https://pkgs.omarchy.org/$channel/$arch/omarchy.db?$RANDOM" | bsdtar -tf - 2>/dev/null)
  if [[ -z $db ]]; then found="COULD NOT READ THE DATABASE"
  else found=$(awk -F/ -v p="<package>" '{n=$1; sub(/-[^-]+-[^-]+$/, "", n)} n==p && $2=="" {print $1}' <<<"$db"); fi
  printf '%-7s %-8s %s\n' "$channel" "$arch" "${found:-not in this channel}"
done; done
```

Compare the result against
[Where a package is published](#where-a-package-is-published) before calling
a missing entry wrong. `<package>` here is the package name, which for a
split package is not always the recipe directory.

List a whole channel:

```bash
curl -fsSL https://pkgs.omarchy.org/stable/aarch64/omarchy.db | bsdtar -tf - | grep '/$'
```

### Read the publish log

Every run that writes a channel (publish, promotion, release candidate)
appends one JSON line to `https://pkgs.omarchy.org/publish-log.jsonl` when it
finishes, newest last. A plan-only run writes nothing there.
A rerun adds another line for the same run. The log records finished runs;
for a cancelled one, [check the channel](#check-that-a-version-is-live).

| Field | Meaning |
|---|---|
| `time`, `commit`, `run` | When, which `master` commit, and the workflow run URL |
| `event` | `push` for a merge, `workflow_dispatch` for a manual run |
| `target` | `live`, or the scratch prefix of a proof run |
| `plan` | Every package, architecture and channel the run set out to publish |
| `sources` | Per package and architecture, where its files came from. Stops at the first one that failed |
| `slots` | Per channel and architecture attempted: `status`, and `packages` as file names without `.pkg.tar.zst` |

`sources[].source` is one of:

| Value | Meaning |
|---|---|
| `pr-artifact` | Used an existing build artifact, from the PR or an earlier run |
| `rebuild` | No artifact existed; built during this run |
| `already-published` | `edge` already held this version; nothing done |
| `build-failed` | No artifact: the build failed, or the artifact expired |
| `artifact-download-failed` | The artifact exists but could not be fetched or unpacked |
| `built`, `native-rebuild`, `native-build-failed` | Written by earlier versions of the workflow: built during the run, or failed to |

`slots[].status` is `published` or `failed`. An empty `slots` means the run
wrote no channel. The fast-ring step's copies into `rc` and `stable` are
slots of the same run.

A [promotion](#promote-a-channel) appends a line with `"kind": "promote"`
(publish runs have no `kind`) and these fields besides `time`, `commit`,
`run`, `event`, `target` and `slots`:

| Field | Meaning |
|---|---|
| `from`, `to` | The channels: `edge` → `rc`, or `rc` → `stable` |
| `actor` | Who started the run |
| `packages` | The pkgbases it was limited to; empty for everything eligible |
| `result` | `success` or `failed` |
| `plan` | Each package promoted: `arch`, `base`, `name`, `from_version`, `to_version` (`null` when new to the destination), `file`, `size` |
| `held` | Per architecture, how many packages stayed back, by reason |

A [release candidate](#releases) appends a line with `"kind": "release-rc"`
and, besides the common fields and `slots`: `pkgver` (the pinned version),
`rc_commit` (the `rc` branch commit its pins came from), `actor` and `result`.

`sources` is always empty on both kinds.

```bash
log=https://pkgs.omarchy.org/publish-log.jsonl

# The last five runs
curl -fsSL $log | tail -5 |
  jq -c '{time, run, slots: [.slots[] | "\(.mirror)/\(.arch) \(.status)"]}'

# Every run that published a package, and where
curl -fsSL $log | jq -c --arg p "<package>" '
  [.slots[] | select(.status == "published" and any(.packages[]; sub("-[^-]+-[^-]+-[^-]+$"; "") == $p))
   | "\(.mirror)/\(.arch)"] as $where
  | select($where | length > 0) | {time, run, published: $where}'

# Every run where something failed
curl -fsSL $log | jq -c '
  select(.result == "failed" or any(.sources[]; .source | test("failed")) or any(.slots[]; .status == "failed"))
  | {time, run, kind: (.kind // "publish"), failed: [.sources[] | select(.source | test("failed")) | "\(.package) \(.arch) \(.source)"]}'
```

A merge also gets a summary of its record as a comment on the PR. The record
itself is kept as an artifact of the run for 90 days: `gh run download <run-id> -n publish-record-<run-id>`.

## When a publish fails

One package without a usable build stops the run before any channel is
written, for every package in that merge.

Find the run and read the failure:

```bash
gh run list -R omacom/omarchy-pkgs --workflow publish.yml --limit 10
gh run view <run-id> -R omacom/omarchy-pkgs                # Which job failed
gh run view <run-id> -R omacom/omarchy-pkgs --log-failed   # Its log
```

Then act on which job failed:

| Failed job | Log says | Do |
|---|---|---|
| `rebuild` | `Makepkg failed for <package>` | The recipe does not build. Fix it in a PR. Meanwhile publish the other packages of that merge: `gh workflow run publish.yml -f packages="<the healthy ones>"` |
| `rebuild` | an error before the package build starts: the builder image, a mirror, the network | Not the recipe. Rerun: `gh run rerun <run-id> --failed` |
| `publish`, step "Collect artifacts" | `no artifact from the rebuild job` | Either that package's build failed (see the `rebuild` job), or its artifact expired mid-run. For the second, rerun every job: `gh run rerun <run-id>` |
| `publish`, step "Collect artifacts" | the artifact could not be downloaded or unpacked | Rerun: `gh run rerun <run-id> --failed`. If it fails again the artifact is bad: bump `pkgrel` in a PR to get a fresh build |
| `publish`, step "Publish" | `Already published with DIFFERENT bytes, refusing to overwrite` | That version is already out with other contents. Bump `pkgrel` in a PR |
| `publish`, step "Publish" | `its artifact has no files with pkgbase <base>` | The build produced packages under another pkgbase than the recipe declares. Fix the recipe's `pkgbase`/`pkgname` in a PR |
| `publish`, step "Publish" | `Upload incomplete`, or an rclone or gpg error | Storage or signing trouble. Rerun: `gh run rerun <run-id> --failed` |
| `publish`, step "Bring the fast ring in line with edge" | `does not match its database entry`, or an rclone or gpg error | `edge`'s file or the bucket is at fault, not the merge: the merge itself published. Rerun: `gh run rerun <run-id> --failed`, or dispatch the package later |
| `publish` shows cancelled | | Someone cancelled it, or it timed out. Merges queue for the publish lock rather than replacing each other. Republish the merge's packages with a dispatch |

**The Publish step writes channels in a fixed order:** `edge` then `rc` then
`stable`, x86_64 before aarch64. It stops at the first one that fails, so the
earlier ones are complete, and running it again finishes the rest: a file
already uploaded with the same bytes is only added to the database.

- Rerun it while the build artifact exists: 7 days from when it was built.
- After that, bump `pkgrel` in a PR to finish the remaining channels.

A run cancelled before the Publish step wrote no channel: republish its
packages with a dispatch.

- Rerun (`gh run rerun`) repeats that merge's commit.
- Dispatch (`gh workflow run publish.yml -f packages=...`) publishes
  `master`'s current version of the named packages.

Afterwards, [check that the version is live](#check-that-a-version-is-live).

**Promote channel and Build release candidate** write the same way: x86_64
first, then aarch64, and a promotion in batches of about 2 GiB. What was
written before a failure is complete, and a rerun picks up where it stopped
(`gh run rerun <run-id> --failed`); the run's summary says what moved. A
promoted file that does not match its source database (`does not match its
database entry`) fails its batch before that batch writes anything.
`bin/omarchy-release` stops when its run fails; run the same command again
once the rerun has passed.

## Who can build and merge

Builds cost machines, so `build-pr.yml` runs them only for trusted authors:

- repository collaborators and bots
- authors listed in `.github/VOUCHED.td`
- any PR a maintainer labels `build-approved` (that PR only, including later
  commits): `gh pr edit <number> -R omacom/omarchy-pkgs --add-label build-approved`

`VOUCHED.td` takes one `github:<username>` per line; `-github:<username>
<reason>` denounces an author.

An unknown author's PR shows **Awaiting build approval** and stays blocked
until one of those applies. An author denounced in `VOUCHED.td` cannot be
overridden by the label.

A trusted PR also merges itself. `auto-merge-pr.yml` enables auto-merge when
the PR is open, not a draft, and changes only packages: files under
`pkgbuilds/`, new files under `tests/`, and `test.yml` lines that only add a
`./tests/<name>.sh` call. Anything touching workflows, scripts, build tooling
or an existing test needs a maintainer to merge it.

- Remove `build-approved` to withdraw the auto-merge it armed for an unknown
  author. Runs it already released keep going.
- If the builds do not start a few minutes after labelling, remove the label
  and apply it again.
- Evaluate a PR by hand: `gh workflow run auto-merge-pr.yml -f pr=<number>`.

## Automatic updates

Three scheduled workflows open PRs, one per package, through
`package-prs.yml`. Each PR auto-merges when its build is green, so the open
ones are the failures. Each workflow takes a `packages` input for a manual run
on named packages.

| Workflow | Runs | Opens one PR per package on | For |
|---|---|---|---|
| `sync-upstream.yml` | every 6 hours | `auto/sync-upstream-<package>` | a new upstream release |
| `sync-rebuilds.yml` | every 6 hours | `auto/sync-rebuilds-<package>` | a `pkgrel` bump where a `rebuild_on` dependency moved |
| `track-branches.yml` | hourly | `auto/track-branches-<package>` | `"auto_merge": true` packages: the newest upstream release or branch tip |

- **A red PR holds back only its own package.** Fix it on `master` or on the
  PR. The next run updates the PR if upstream moves again, and closes it once
  it conflicts with `master`. Packages pinned from the same upstream branch
  (`omarchy-dev` and `omarchy-settings-dev`) share a PR, because they move in
  lockstep.
- **A package with no upstream declaration or hook gets no upstream updates.** That
  includes the kernels (`linux-omarchy*`, `linux-ptl`, `linux-aurora`): bump
  them by PR.
- A failed run of any of the three posts to Basecamp when
  `BASECAMP_CHATBOT_URL` is set.
- Every self-merging path (the three above and `auto-merge-pr.yml`) needs
  the `PKGS_BOT_TOKEN` secret: a personal access token with Contents and Pull
  requests write access to this repository, owned by an account trusted to
  build. A merge made with the built-in `GITHUB_TOKEN` does not start
  `publish.yml`.

Details: [docs/upstream-sources.md](docs/upstream-sources.md),
[docs/rebuild-triggers.md](docs/rebuild-triggers.md).

## Package metadata

`pkgbuilds/<package>/.omarchy/package.json`:

```json
{ "source": "local" }
{ "source": "local", "release_ring": "fast" }
{ "source": "local", "upstream": { "watch": { "github": "abenz1267/walker", "pattern": "v(?P<version>[0-9]+(?:\\.[0-9]+)*)" } } }
```

| Field | Meaning |
|---|---|
| `source` | Always `local`. |
| `upstream` | Where releases come from. Mutually exclusive with an `.omarchy/upstream.sh` hook. |
| `min_release_age` | Hold a new upstream release back this long (`"24h"`, `"2d"`). A release whose age cannot be proven fails the sync. |
| `auto_merge` | `true` moves the package's updates from `sync-upstream.yml` (every 6 hours) to `track-branches.yml` (hourly). For packages that follow a moving branch, and for feeds worth shipping within the hour. Needs an upstream declaration. |
| `release_ring` | `fast`: publish to `rc` and `stable` on merge, not only `edge`. Only for packages that run on any channel's libraries: see [What can be on the fast ring](#what-can-be-on-the-fast-ring). Takes effect with the package's next version: bump `pkgrel` in the same PR. |
| `channels` | The only channels the package may be published to. `omarchy-dev` is held to `["edge"]` this way. |
| `pinned` | Version is set per release on the `rc` branch. Used by `omarchy` and `omarchy-settings`. |
| `rebuild_on` | Packages whose version change forces a rebuild of this one. |
| `rebuilt_against` | Written by `bin/sync-rebuilds`. Don't edit. |
| `skip_build` | Leaves the package out of an unscoped local `bin/build`. CI ignores it: a PR that touches the package builds and publishes it. |
| `sync` | `false` holds the package out of upstream updates, with or without an `upstream` declaration. |
| `origin` | Where an imported recipe came from. Informational. |

## Releases

`bin/omarchy-release` runs a release train from a workstation. It pins the
`omarchy` and `omarchy-settings` pair on the `rc` branch, then drives the
workflows that do the work:

- **Build release candidate** (`release-rc.yml`) builds the `rc` branch's pins
  for both architectures and publishes them to `rc`.
- **Promote channel** (`promote.yml`) carries `rc` into `stable` when the
  train ships, and `edge` into `rc` when a minor or major train opens.

Both can also be run from the Actions tab. Read
[docs/releases.md](docs/releases.md) before cutting a release.

## Rules

- **Write channels through the workflows only.** `publish.yml`,
  `promote.yml`, `release-rc.yml` and `unpublish.yml` share one lock, so only
  one of them writes a channel database at a time. Anything else that writes
  the bucket can overwrite a database another run just wrote.
- **Never reuse a published filename for different bytes.** The CDN caches
  package files by name and keeps serving the old ones. Bump `pkgrel`.
- **Don't merge a package PR before its builds are green.** `publish.yml`
  then has to build the missing packages, and one that fails stops the whole
  merge from publishing.
- **Don't cancel a publish run.** If one is cancelled, republish its packages
  with a dispatch.
- **Check after a manual publish.** Confirm the package and version are in
  the channel database for each architecture it ships to.

## Layout

```
pkgbuilds/<package>/           Recipe: PKGBUILD and .omarchy/package.json
bin/                           Tooling the workflows and local work call
build/                         Builder image and the in-container build script
helpers/                       Shell and Python shared by bin/ and the workflows
ci/                            x86_64 builder pool: controller and runner setup
tests/                         Tests; test.yml runs them on every PR
docs/                          Reference
.github/workflows/             The pipeline
.github/VOUCHED.td             Authors trusted to build
```

| Workflow | Trigger | Does |
|---|---|---|
| `build-pr.yml` | PR, dispatch | Builds changed packages; reports `result` |
| `test.yml` | PR, dispatch | `self-tests` and `build-isolation` |
| `publish.yml` | push to `master`, dispatch | Signs and publishes; brings `rc` and `stable` in line with `edge` for the fast ring |
| `promote.yml` | dispatch | Promote channel: `edge` → `rc`, `rc` → `stable` |
| `release-rc.yml` | dispatch | Build release candidate: the `rc` branch's pins into `rc` |
| `unpublish.yml` | dispatch | Removes retired packages from channel databases |
| `auto-merge-pr.yml` | PR events, dispatch | Enables auto-merge on trusted package PRs |
| `approve-pr.yml` | PR events | Releases GitHub's hold on a `build-approved` PR's runs |
| `sync-upstream.yml` | every 6 hours, dispatch | Upstream release PR |
| `sync-rebuilds.yml` | every 6 hours, dispatch | Dependency rebuild PR |
| `track-branches.yml` | hourly, dispatch | Branch tip PRs |
| `package-prs.yml` | called by the sync workflows | Opens, updates and closes their PRs |
| `builder-images.yml` | daily, changes to the image's inputs (push and PR), dispatch | Builds and tests the builder image; publishes it from `master` |

Secrets: the `publish` environment (usable from `master` only) holds the
signing key and bucket credentials: `GPG_PRIVATE_KEY`, `GPG_PASSPHRASE`,
`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`. Its variable
`OMARCHY_PUBLISH_PREFIX` redirects every bucket write to a scratch prefix
in the bucket for a proof run; it must be empty for live publishing.
Repository secrets: `PKGS_BOT_TOKEN`, `BASECAMP_CHATBOT_URL`.

## More

- [ci/README.md](ci/README.md): the x86_64 builder pool and how to operate it
- [docs/builds.md](docs/builds.md): dependency order, isolation, builder images
- [docs/upstream-sources.md](docs/upstream-sources.md): declaring upstream releases
- [docs/rebuild-triggers.md](docs/rebuild-triggers.md): rebuilding when a dependency moves
- [docs/releases.md](docs/releases.md): cutting a release, versioning rules
