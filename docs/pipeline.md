# How the pipeline works

What happens between a PR and a published package, and the rules around it.

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
  └─ release-rc.yml     Build release candidate: the rc branch's pins -> rc, edge
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
   appends to the [publish log](operations.md#read-the-publish-log).

Nothing else moves on its own: `rc` and `stable` change only when someone
[promotes](operations.md#promote-a-channel) them or [cuts a release](#releases).

A package is built once and that one file is what every channel serves.
**A published filename never changes its bytes.** To ship a different build
of the same version, bump `pkgrel`.

## Where a package is published

`bin/build-matrix` decides, from `.omarchy/package.json`. The release ring is
the only choice a package makes:

| Package | Published on merge to |
|---|---|
| Default (normal ring) | `edge`; `rc` and `stable` by [promotion](operations.md#promote-a-channel) |
| `"release_ring": "fast"` | `edge`, `rc` and `stable` |
| `"pinned": true` (`omarchy`, `omarchy-settings`) | `edge`; `rc` only through a [release candidate](#releases), `stable` by promotion |

Every package reaches every channel. Nothing is held to edge: a package that
must not reach rc yet is left out of the promotion by naming the ones that
should go.

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
its current build along (see [Republish a package](operations.md#republish-a-package)).

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

Two scheduled workflows open PRs, one per package, through
`package-prs.yml`. The controller box starts them on systemd timers (see
[`ci/README.md`](../ci/README.md#scheduled-workflows)), not GitHub's `schedule`,
which ran them hours late. Each PR auto-merges when its build is green, so
the open ones are the failures. Each workflow takes a `packages` input for a manual run
on named packages.

| Workflow | Runs | Opens one PR per package on | For |
|---|---|---|---|
| `sync-upstream.yml` | every 6 hours | `auto/sync-upstream-<package>` | upstream updates for packages without `"auto_merge": true` |
| `sync-upstream.yml` | hourly | `auto/track-branches-<package>` | `"auto_merge": true` packages: the newest upstream release or branch tip |
| `sync-rebuilds.yml` | every 6 hours | `auto/sync-rebuilds-<package>` | a `pkgrel` bump where a `rebuild_on` dependency moved |

For a manual upstream run, choose the `hourly` or `six-hourly` package group
with the `cadence` input (default: `six-hourly`). The historical PR branch
prefixes remain unchanged so existing PRs keep receiving updates. The separate
`track-branches.yml` workflow has been retired.

- **A red PR holds back only its own package.** Fix it on `master` or on the
  PR. The next run updates the PR if upstream moves again, and closes it once
  it conflicts with `master`. Packages pinned from the same upstream branch
  (`omarchy-dev` and `omarchy-settings-dev`) share a PR, because they move in
  lockstep.
- **A package with no upstream declaration or hook gets no upstream updates.** That
  includes the kernels (`linux-omarchy*`, `linux-aurora`): bump
  them by PR.
- `sync-upstream.yml` reports each completed run to Basecamp when
  `BASECAMP_CHATBOT_URL` is set, identifying the hourly or six-hourly group.
  Individual package update and PR check
  failures leave the completed sync green; its notification and Actions
  summary give counts and link to the affected PRs. PR update results and
  current PR check results are counted separately: checks still running (or
  not started yet) are pending, and the sync does not wait for builds.
  Feed-fetch, setup, and missing-result failures still fail the workflow.
  A failed `sync-rebuilds.yml` run also posts to Basecamp.
- Every self-merging path (both workflows and `auto-merge-pr.yml`) needs
  the `PKGS_BOT_TOKEN` secret: a personal access token with Contents and Pull
  requests write access to this repository, owned by an account trusted to
  build. A merge made with the built-in `GITHUB_TOKEN` does not start
  `publish.yml`.

Details: [docs/upstream-sources.md](upstream-sources.md),
[docs/rebuild-triggers.md](rebuild-triggers.md).

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
| `auto_merge` | `true` selects the hourly group in `sync-upstream.yml`; other packages are checked every 6 hours. Both groups auto-merge passing PRs. For packages that follow a moving branch, and for feeds worth shipping within the hour. Needs an upstream declaration. |
| `release_ring` | `fast`: publish to `rc` and `stable` on merge, not only `edge`. Only for packages that run on any channel's libraries: see [What can be on the fast ring](#what-can-be-on-the-fast-ring). Takes effect with the package's next version: bump `pkgrel` in the same PR. |
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
  for both architectures and publishes them to `rc`, then carries the same
  files to `edge` when newer than what edge serves.
- **Promote channel** (`promote.yml`) carries `rc` into `stable` when the
  train ships, and `edge` into `rc` when a minor or major train opens.

Both can also be run from the Actions tab. Read
[docs/releases.md](releases.md) before cutting a release.

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
| `release-rc.yml` | dispatch | Build release candidate: the `rc` branch's pins into `rc`, then `edge` |
| `unpublish.yml` | dispatch | Removes retired packages from channel databases |
| `auto-merge-pr.yml` | PR events, dispatch | Enables auto-merge on trusted package PRs |
| `approve-pr.yml` | PR events | Releases GitHub's hold on a `build-approved` PR's runs |
| `sync-upstream.yml` | hourly and every 6 hours, dispatch | Upstream release and branch-tip PRs, with a result notification for either package group |
| `sync-rebuilds.yml` | every 6 hours, dispatch | Dependency rebuild PR |
| `package-prs.yml` | called by the sync workflows | Opens, updates and closes their PRs |
| `builder-images.yml` | daily, changes to the image's inputs (push and PR), dispatch | Builds and tests the builder image; publishes it from `master` |

Secrets: the `publish` environment (usable from `master` only) holds the
signing key and bucket credentials: `GPG_PRIVATE_KEY`, `GPG_PASSPHRASE`,
`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`. Its variable
`OMARCHY_PUBLISH_PREFIX` redirects every bucket write to a scratch prefix
in the bucket for a proof run; it must be empty for live publishing.
Repository secrets: `PKGS_BOT_TOKEN`, `BASECAMP_CHATBOT_URL`.
