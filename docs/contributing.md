# Contributing a package

How to add, update or fix a package, and what happens to the PR.

## Before you start

Everything a package PR needs is in `pkgbuilds/<package>/`. No secrets or
access are required. To work locally you need:

- `git`, `bash`, `jq`, `curl` and a `tar` that reads zstd
- Docker or Podman that your user can run, to build. With Docker, a build
  calls `sudo` to fix the ownership of its output.
- on Arch, to check an upstream declaration: Python 3.11+, `vercmp`, `bsdtar`

Questions and problems: open an issue on this repository.

## Add a new package

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
   another PR. See [docs/upstream-sources.md](upstream-sources.md).

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

## Update or fix an existing package

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

## What happens to your PR

1. **It waits for build approval** unless you are a collaborator or listed
   in `.github/VOUCHED.td`. A maintainer starts the builds by labelling the
   PR `build-approved`. Until then it shows **Awaiting build approval**, or,
   for your first PR here, GitHub's own "workflows awaiting approval".
   Builds cost machines, so they run for trusted authors only.
2. **CI builds the package** for each architecture and runs the tests. The
   required checks are `result`, `self-tests` and `build-isolation`.
3. **It merges itself when green**, if it changes only package files.
4. **It is published to `edge`** within minutes of merging, and reaches
   `rc` and `stable` with the next release. Say so in the PR if you think the
   package should reach `stable` immediately (the fast ring).

Keep a package PR to these files, or it needs a maintainer to merge it by
hand:

- anything under `pkgbuilds/`
- a new test under `tests/`, and the one line in `.github/workflows/test.yml`
  that runs it

Changes to `bin/`, `helpers/`, `build/` or the workflows go in a separate PR,
first: a PR's packages are built with `master`'s tooling, not its own.
