# Cutting an Omarchy release

The release train runs from `bin/omarchy-release`. Nothing in the GitHub
workflows promotes a channel: its channel moves and RC builds were written to
execute on the old repository host, which is abandoned (see
[repository-host.md](repository-host.md)), against a local copy of the
published tree.

> `rc` and `ship` build the release pair with `bin/repo release` and move
> channels with `bin/repo advance`, on the machine that holds the published
> tree. No workflow replaces them yet. That machine's tree has to match the
> bucket first: `advance` reads the source channel from local disk.

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
a commit no RC was cut from. One exception: `ship` carries on past a failed
ISO or website step, and a later `ship` exits once stable holds the version
and the GitHub release exists. Finish a failed ISO or website step by hand.

## Promoting a channel

Ship the tested rc channel to stable (copies packages + signatures, then
cleans, rebuilds the database, and syncs):

```
bin/repo advance --from rc --to stable --arch all
```

Open a release train that ships new edge packages by carrying edge into rc
first:

```
bin/repo advance --from edge --to rc --arch all
```

`advance` moves x86_64 alone unless given `--arch`. `--arch all` covers the
architectures in `PUBLISHED_ARCHES` (`helpers/paths.sh`), x86_64 only by
default; set `OMARCHY_ARCHES="x86_64 aarch64"` on the machine that runs it to
promote both. The variable is not carried over when `bin/repo` forwards a
command over ssh, and `omarchy-release ship` promotes through the same path. It refuses to
carry a package into a channel its `channels` metadata excludes.

## The pin engine

The release pair is marked `"pinned": true`. It is built for `rc` only from
the `rc` branch worktree, with `OMARCHY_RC_PINS=1` set (`omarchy-release rc`
sets it), and never built for `stable`: stable gets it by promotion. A merge to
`master` therefore cannot overwrite an RC in flight.

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
- **Finals build into rc, then the whole channel promotes.** After testing, the
  ship step promotes the exact tested artifacts (packages and signatures)
  forward:

```bash
bin/repo advance --from rc --to stable --arch all
```

Neither package is on the `fast` ring, and `bin/omarchy-pkgs` never touches
stable — promotion is always this explicit step.
