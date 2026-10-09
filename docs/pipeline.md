# How the pipeline works

What happens between a PR and a published package, and the rules around it.

## How a package reaches users

```
PR touching pkgbuilds/<package>/
  └─ build-pr.yml       one build per package and architecture, unsigned
merge to master
  └─ publish.yml        collect the builds, sign, add to the channel
                        databases, upload
pkgs.omarchy.org        served from the R2 bucket omarchy-pkgs through a CDN
```

To ship a change: open a PR, wait for green, merge. Nothing else is needed.

1. **Build.** `build-pr.yml` builds every package directory the PR touches,
   once, against `edge`. x86_64 builds on an ephemeral DigitalOcean droplet
   (runner label `omarchy-builder`), aarch64 on GitHub's `ubuntu-24.04-arm`.
   Each build is kept as a workflow artifact for 7 days, named
   `<package>-<arch>-<git tree hash of the package directory>`.
2. **Merge.** Branch protection requires `result`, `self-tests` and
   `build-isolation`. Don't merge around a red check.
3. **Publish.** `publish.yml` runs on every push to `master` that touches
   `pkgbuilds/**`. It finds the artifact for exactly the merged tree, signs
   it, and publishes it to every channel and architecture the package ships
   to. When no artifact exists it builds one first, in a separate job. It
   reports in a comment on the merged PR and appends to the
   [publish log](operations.md#read-the-publish-log).

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
| `"pinned": true` (`omarchy`, `omarchy-settings`) | `edge`; `rc` and `stable` only through a release |

A package is published for each architecture in its `arch=()`. An `arch=any`
package builds once and goes into both architectures' databases.

Everything not on the fast ring reaches `rc` and `stable` by promotion: see
[Releases](#releases).

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

Three scheduled workflows open PRs. Each takes a `packages` input for a manual
run on named packages; for the two sync workflows that run opens its own PR,
on `auto/sync-upstream-<packages>` or `auto/sync-rebuilds-<packages>`.

| Workflow | Runs | Opens | Merges |
|---|---|---|---|
| `sync-upstream.yml` | every 6 hours | one PR on `auto/sync-upstream` with every new upstream release | **a maintainer merges it** |
| `sync-rebuilds.yml` | every 6 hours | one PR on `auto/sync-rebuilds` bumping `pkgrel` where a `rebuild_on` dependency moved | itself, when green |
| `track-branches.yml` | every 2 hours | one PR on `auto/track-branches` updating `"auto_merge": true` packages to their newest upstream release or branch tip | itself, when green |

- **Each PR is a batch.** One package that fails to build keeps the whole PR
  red and unmerged. Fix that package on `master`. For the two sync workflows,
  a run with `packages` naming the healthy ones gives them their own PR. The
  branch tracker has one PR only; its next run replaces it.
- **A package with no upstream declaration or hook gets no upstream updates.** That
  includes the kernels (`linux-omarchy*`, `linux-ptl`, `linux-aurora`): bump
  them by PR.
- A failed run of any of the three posts to Basecamp when
  `BASECAMP_CHATBOT_URL` is set.
- Every self-merging path (`sync-rebuilds.yml`, `track-branches.yml` and
  `auto-merge-pr.yml`) needs
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
| `auto_merge` | `true` moves the package's updates from the reviewed sync PR to `track-branches.yml`. For packages that follow a moving branch, and for trusted vendor and Omacom release feeds. Needs an upstream declaration. |
| `release_ring` | `fast`: publish to `rc` and `stable` on merge, not only `edge`. Takes effect with the package's next version: bump `pkgrel` in the same PR. |
| `channels` | The only channels the package may be published to. `omarchy-dev` is held to `["edge"]` this way. |
| `pinned` | Version is set per release on the `rc` branch. Used by `omarchy` and `omarchy-settings`. |
| `rebuild_on` | Packages whose version change forces a rebuild of this one. |
| `rebuilt_against` | Written by `bin/sync-rebuilds`. Don't edit. |
| `skip_build` | Left the package out of the old host's unscoped builds. CI ignores it: a PR that touches the package builds and publishes it. |
| `sync` | `false` holds the package out of upstream updates, with or without an `upstream` declaration. |
| `origin` | Where an imported recipe came from. Informational. |

## Releases

Cutting an Omarchy release and promoting a channel are **not** in the GitHub
workflows. They are done with `bin/omarchy-release` and `bin/repo advance`,
which were written for the old repository host, now abandoned, and work on a
local copy of the published tree.

Read [docs/releases.md](releases.md) before cutting a release or
promoting a channel.

## Rules

- **Publish through `publish.yml` only.** Don't run `bin/repo release`,
  `sync`, `push` or `deploy`. A second publisher overwrites the channel
  database the first one wrote. The release train is the one exception: see
  [docs/releases.md](releases.md).
- **Don't bring the old host's release timers back.** They run
  `bin/repo release` every five minutes. Run `bin/setup` with
  `--skip-timers`.
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
systemd/                       Release timers for the repository host (abandoned)
tests/                         Tests; test.yml runs them on every PR
docs/                          Reference
.github/workflows/             The pipeline
.github/VOUCHED.td             Authors trusted to build
```

| Workflow | Trigger | Does |
|---|---|---|
| `build-pr.yml` | PR, dispatch | Builds changed packages; reports `result` |
| `test.yml` | PR, dispatch | `self-tests` and `build-isolation` |
| `publish.yml` | push to `master`, dispatch | Signs and publishes |
| `unpublish.yml` | dispatch | Removes retired packages from channel databases |
| `auto-merge-pr.yml` | PR events, dispatch | Enables auto-merge on trusted package PRs |
| `approve-pr.yml` | PR events | Releases GitHub's hold on a `build-approved` PR's runs |
| `sync-upstream.yml` | every 6 hours, dispatch | Upstream release PR |
| `sync-rebuilds.yml` | every 6 hours, dispatch | Dependency rebuild PR |
| `track-branches.yml` | every 2 hours, dispatch | Branch tip PR |
| `builder-images.yml` | daily, changes to the image's inputs (push and PR), dispatch | Builds and tests the builder image; publishes it from `master` |

Secrets: the `publish` environment (usable from `master` only) holds the
signing key and bucket credentials: `GPG_PRIVATE_KEY`, `GPG_PASSPHRASE`,
`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`. Its variable
`OMARCHY_PUBLISH_PREFIX` redirects publish and unpublish to a scratch prefix
in the bucket for a proof run; it must be empty for live publishing.
Repository secrets: `PKGS_BOT_TOKEN`, `BASECAMP_CHATBOT_URL`.
