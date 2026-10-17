# Cutting an Omarchy release

The release train runs from `bin/omarchy-release` on a workstation, with
`gh` signed in. The script pins the release pair, pushes branches and tags,
and starts the two workflows that build and move packages:

- **Build release candidate** (`.github/workflows/release-rc.yml`) builds the
  `omarchy` and `omarchy-settings` pins on this repository's `rc` branch for
  both architectures and publishes them to `rc`.
- **Promote channel** (`.github/workflows/promote.yml`) carries one channel
  into the next ([below](#promoting-a-channel)).

Both run on the bucket inside the same lock as merges, and each records who
started it and what it published, in its run summary and in the
[publish log](../README.md#read-the-publish-log).

`bin/omarchy-release` is the front door. A release train has three human
moments, each one command — and bare `omarchy-release` observes reality
(branches, pins, published channels, tags) and walks you to the next one:

```bash
bin/omarchy-release              # shepherd: status + guided next step
bin/omarchy-release start 4.0.2  # open the train: branch v4-0-2 + staging PR
                                 # (a minor/major also promotes edge → rc)
bin/omarchy-release pick         # choose merged PRs to cherry-pick (multi-select)
bin/omarchy-release rc           # pin the next 4.0.2rcN, build it into rc
bin/omarchy-release ship         # tag, final pins built into rc, promote rc → stable,
                                 # draft GitHub release, ISO, website — one swoop
bin/omarchy-release doctor       # verify credentials/connections up front
```

`rc` and `ship` print each workflow run's URL and follow it to the end
(`--no-wait` starts it and returns). A failed run stops the command; fix the
cause and re-run it. To build the current pins again without cutting new
ones, run **Build release candidate** from the Actions tab, or:

```bash
gh workflow run release-rc.yml -R omacom/omarchy-pkgs
```

Versions are inferred from branch names (`v4-0-2` ⇒ `4.0.2rcN` ⇒ tag
`v4.0.2`); `start` is the only place a version is typed. Every command is
idempotent — re-runs skip whatever is already done. `ship` refuses to promote
a commit no RC was cut from. One exception: `ship` carries on past a failed
ISO or website step, and a later `ship` exits once stable holds the version
and the GitHub release exists. Finish a failed ISO or website step by hand.

## Promoting a channel

Run **Promote channel** (`.github/workflows/promote.yml`) from the Actions
tab. It works on the bucket directly, both architectures, inside the same
lock as merges, and records who ran it and what moved; see
[Promote a channel](../README.md#promote-a-channel) for what it holds back.

Carry what has landed on edge into rc, so RC testing runs against the
package set stable users will get:

```bash
gh workflow run promote.yml -R omacom/omarchy-pkgs -f direction="edge -> rc"
```

Ship the tested rc channel to stable, the release pair included:

```bash
gh workflow run promote.yml -R omacom/omarchy-pkgs -f direction="rc -> stable"
```

Add `-f dry_run=true` to see the plan first.

## The pin engine

The release pair is marked `"pinned": true`. It is built for `rc` only by
**Build release candidate**, which takes the pins from the `rc` branch and sets
`OMARCHY_RC_PINS=1`, and never built for `stable`: stable gets it by promotion.
A merge to `master` therefore cannot overwrite an RC in flight.

The `omarchy` and `omarchy-settings` packages are released as a pair, always
built from the same upstream commit of basecamp/omarchy.

**Use `bin/omarchy-release`** — it drives the whole train across all four repositories and
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

## Versioning rules

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

## Where releases land

- **RCs build for the rc channel.** RC testers and RC ISO installs run the real
  `omarchy` package against the package set stable users will actually get.
  Stable never sees an rc version; rc testers upgrade rc1 → rc2 → final
  naturally.
- **Finals build into rc, then the whole channel promotes.** After testing,
  the exact tested packages move forward:

```bash
gh workflow run promote.yml -R omacom/omarchy-pkgs -f direction="rc -> stable"
```

Neither package is on the `fast` ring, and `bin/omarchy-pkgs` never touches
stable — promotion is always this explicit step.
