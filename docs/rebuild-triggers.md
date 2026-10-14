# Rebuild triggers

```bash
bin/sync-rebuilds                       # Bump every package whose dependencies moved
bin/sync-rebuilds quickshell-git        # Update specific packages
bin/sync-rebuilds --self-test           # Run the regression tests
```

Some packages have to be rebuilt when something they link against changes, even though nothing in their own source moved. A Qt private-API consumer is the usual case: `Qt_6_PRIVATE_API` symbols are not covered by the soname, so a qt6-base point release can leave an installed binary unable to resolve a symbol at startup, and pacman upgrades Qt out from under it because the dependency is unversioned. The package still builds from the same git commit, so its version alone would not trigger a rebuild.

A package names those dependencies in `.omarchy/package.json`:

```json
{ "source": "local", "rebuild_on": ["qt6-base", "qt6-declarative", "qt6-wayland"] }
```

`bin/sync-rebuilds` reads each named package's version from the official
repositories for every architecture a merge builds (`CI_ARCHES` in
`helpers/paths.sh`, both by default) that the package supports and compares
it to `rebuilt_against`. Records are kept per architecture because Arch and
Arch Linux ARM can carry different dependency versions. pkgrel is bumped once
when any recorded version moves; that one source revision is then built for
each architecture by the PR that carries the bump.

The bump is the point of the command, and it has to land in git rather than in the builder. A rebuild that reuses the published version string produces a package pacman will never offer anyone, so rebuilding without a version change would ship nothing. Bumping pkgrel needs no other change: the PR that carries the bump builds the package, and the merge publishes it.

The bumped version is checked against the published one as well as the checked-in one, and refused when pacman would not order it higher. The checked-in version is not the floor; what a user already has is, and a checkout that has fallen behind the repository can otherwise be bumped to something that loses to the package it means to replace. That check is skipped with a warning when the published database cannot be read.

x86_64 versions are read from the local pacman database, so the workflow runs
in an Arch container pointed at `mirror.omarchy.org`, the same mirror as the
x86_64 builder. aarch64 versions are read directly from the live Arch Linux ARM
repository database, which is also what the ARM builder uses. Testing and
staging repositories do not count. A legacy flat `rebuilt_against` record is
read as x86_64 and is migrated naturally the next time a rebuild is needed.

A dependency this repository carries for an architecture (a recipe here that builds for edge on it, such as aquamarine on aarch64) shadows the distribution's, because the builder lists `[omarchy]` first. Its version is the recipe's, and it counts only once edge publishes that version: until then the builder still links against the previous one, so dependents are left alone for that run.

## The workflow

`sync-rebuilds.yml` runs `bin/sync-rebuilds` every 6 hours and opens one PR per
package on `auto/sync-rebuilds-<package>` with auto-merge enabled. Each PR lands
once `result`, `self-tests` and `build-isolation` pass, and the merge publishes.
A rebuild that fails stays an open red PR for a maintainer without holding back
the others.
