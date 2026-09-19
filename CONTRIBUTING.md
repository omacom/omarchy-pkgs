# Contributing to omarchy-pkgs

## Local setup

```bash
git clone https://github.com/omacom/omarchy-pkgs.git
cd omarchy-pkgs
```

You need: `bash`, `git`, `jq`, `python3` (3.11+), `curl`, and a container
engine (`docker`; `CONTAINER_ENGINE=docker` for tests). The full self-test
suite runs inside `archlinux:base-devel` because version ordering uses Arch's
`vercmp`, and packaging steps use `makepkg`/`repo-add`/`bsdtar`. Only the
publish-artifact test additionally needs `rclone`.

`bin/build` works from a bare clone: with no local published tree it plans
against and resolves from `https://pkgs.omarchy.org/<mirror>/<arch>`. Commands
that operate on the published tree (`release`, `build`, `sign`, `promote`,
`update`, `clean`, `advance`, `sync`, …) run on the repository host over ssh
when one is configured (`--host`, `OMARCHY_REPO_HOST`, or the git-ignored
`.repo-host` file); pass `--local` to force execution on the current machine.
Local package builds need no secrets: signing and publishing happen on the host.

Layout:

- `pkgbuilds/<package>/PKGBUILD` + `.omarchy/package.json` (optional
  `.omarchy/upstream.sh`) — one directory per package; this is what most PRs touch
- `bin/`, `helpers/`, `build/` — repo tooling
- `tests/` — shell/Python regression tests plus the `build-isolation` fixture
- `docs/upstream-sources.md` — direct upstream watches
- `.github/workflows/` — `test.yml`, `build-pr.yml`, `publish.yml`,
  `sync-upstream.yml`, `sync-rebuilds.yml`

## Conventions

- Shell scripts use `#!/bin/bash` with `set -euo pipefail` and share helpers
  from `helpers/` (`message-helpers.sh`, `paths.sh`, `host-helpers.sh`, …).
  Check syntax with `bash -n <script>`; there is no separate lint workflow.
- Python (e.g. `helpers/upstream-watch.py`) targets stdlib + `jq`/`curl`/`git`
  tooling; check with `python3 -m py_compile <file>`.
- PKGBUILDs follow Arch packaging standards. Omarchy owns every checked-in
  recipe: edit `PKGBUILD` directly for packaging/architecture behavior.
- Package metadata lives in `pkgbuilds/<package>/.omarchy/package.json`:
  `source`, `upstream` watch/provider (mutually exclusive with
  `.omarchy/upstream.sh`), `sync: false` maintenance holds, `origin`
  provenance, `release_ring: "fast"`, `channels`, `pinned`, `skip_build`,
  `rebuild_on`/`rebuilt_against`. See the README "Package Metadata" section.
- Versioning: reset `pkgrel` to 1 on every version change; bump `pkgrel` by
  hand only to repackage the same source. Pre-releases use the attached form
  only (`X.Y.ZalphaN` / `X.Y.ZbetaN` / `X.Y.ZrcN`); never set `epoch`.
- Keep PRs focused on one concern. Do not mix tooling (`bin/`, `helpers/`,
  `build/`) and `pkgbuilds/` changes in one PR: PR builds compile the PR's
  package directories with the base branch's tooling, so land tooling first.
- Adding a package: `bin/add-package <name> --source aur` (one-time import;
  records `origin`) or `bin/add-package <name> --local --scaffold`, then
  declare an `upstream` watch/provider or hook per `docs/upstream-sources.md`
  and verify with `python helpers/upstream-watch.py check pkgbuilds/<name>`
  and `bin/sync-upstream <name>`.

## Branches

Branch from `master` (the `rc` branch is managed by `bin/omarchy-release`):

```bash
git checkout master && git pull
git checkout -b add-<package>      # new package, e.g. add-yay
git checkout -b fix/<short-scope>  # bug fix, e.g. fix/cua-hyprland-pkgrel
```

Use short kebab-case names: `add-<package>`, `fix/<scope>`,
`feat/<scope>`, `revert-<pr>-<slug>`. The `auto/` prefix is reserved for
automation (`auto/sync-upstream`, `auto/sync-rebuilds`). Release branches
(`vX-Y-Z`) are created by `bin/omarchy-release start X.Y.Z`, not by hand.

## Issues and pull requests

Issues have no template. Include the package name, checked-in vs. published
versions, what you expected, what happened, and the failing command plus its
log excerpt.

Open PRs against `master` with:

- a focused diff and a description of what changed and why,
- the package/version affected (for recipe PRs),
- how you verified it (dry-run plan, explicit build, self-tests),
- docs updated when behavior changes (`README.md`, `docs/upstream-sources.md`).

PR expectations:

- One package or one tooling concern per PR; keep it reviewable.
- Recipe-only changes at the same version bump `pkgrel`; version changes
  reset it.
- CI must be green. Required checks are `result` (every touched package
  builds against `edge` per architecture), `self-tests`, and
  `build-isolation`. A PR whose diff vs. its base is empty fails `result`;
  close it instead of merging.
- New packages need an upstream watch/provider/hook or an explicit
  `sync: false` hold, and must build with the commands below.
- Merging to `master` publishes: `publish.yml` signs and publishes the exact
  built artifacts into each channel the package ships to. Never commit build
  output (`build-output/`) or the published tree (`pkgs.omarchy.org/`).

Note: PR builds run on self-hosted builders for trusted authors
(collaborators, `.github/VOUCHED.td`, or the `build-approved` label).
Untrusted PRs stay pending until a maintainer vouches or labels them.

## Tests

Per-package check before submitting:

```bash
bin/build --dry-run --mirror edge --arch x86_64 --package <name>
CONTAINER_ENGINE=docker bin/build --mirror edge --arch x86_64 --package <name>
```

Full suite (same as `test.yml`):

```bash
docker build -t omarchy-build-isolation-test -f tests/build-isolation.Dockerfile tests
CONTAINER_ENGINE=docker TEST_BUILDER_IMAGE=omarchy-build-isolation-test tests/build-isolation.sh
docker run --rm -v "$PWD:/workspace:ro" -w /workspace archlinux:base-devel bash -lc '
  set -euo pipefail
  pacman -Syu --noconfirm git jq python libarchive
  python tests/upstream-watch.py
  ./bin/sync-upstream self-test
  ./bin/sync-rebuilds --self-test
  ./bin/omarchy-pkgs self-test
  ./bin/omarchy-release self-test
  ./tests/partial-release.sh
  ./tests/published-build-plan.sh
  ./tests/controller.sh
  pacman -S --noconfirm --quiet rclone >/dev/null
  ./tests/publish-artifact.sh
'
```

Run at minimum the self-test lines for the area you touched; run the whole
block before tooling changes. There is no linter to run — CI is the test
suite plus the per-package `edge` builds above.
