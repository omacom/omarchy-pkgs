# Omarchy Package Repository

Recipes for the packages at `https://pkgs.omarchy.org/<channel>/<arch>`.
Channels: `edge` → `rc` → `stable`.

**Ship a package:** change `pkgbuilds/<package>/`, open a PR, merge when
green. It is on `edge` within minutes of the merge.

```bash
bin/add-package my-package --local --scaffold                            # Start a new package
bin/build --package my-package                                           # Build it locally
gh workflow run sync-upstream.yml -f cadence=hourly -f packages="gliff"  # Pick up a new upstream release now
gh workflow run publish.yml -f packages="gliff"                          # Publish master's version where it is missing
gh workflow run unpublish.yml -f packages="gliff"                        # Retire it, after deleting its recipe
```

Set per package in `pkgbuilds/<package>/.omarchy/package.json`:

```
"upstream": { "watch": { "github": "owner/project", "pattern": "v(?P<version>[0-9.]+)" } }
"release_ring": "fast"      publish to rc and stable on merge, not only edge
"auto_merge": true          check upstream hourly, not every 6 hours
"min_release_age": "24h"    hold a new upstream release back this long
```

Bump `pkgrel` to ship a changed build of the same version.

More: [contributing](docs/contributing.md) · [operating](docs/operations.md) ·
[how it works](docs/pipeline.md) · [builders](ci/README.md) ·
[builds](docs/builds.md) · [upstream sources](docs/upstream-sources.md) ·
[rebuild triggers](docs/rebuild-triggers.md) · [releases](docs/releases.md)
