# Operating the pipeline

Tasks for maintainers: republish, build, retire, promote, verify, and recover a failed publish.

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
channel holds a newer version of, or one the destination lacks. With
`packages` it moves only those. Otherwise it is everything on the source
channel, except:

| Held back | Why |
|---|---|
| `"release_ring": "fast"` | Already published to `rc` and `stable` at merge |
| `"pinned": true`, into `rc` | The release pair reaches `rc` through a release; `rc -> stable` carries it |
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
[Where a package is published](pipeline.md#where-a-package-is-published) before calling
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

A [release candidate](pipeline.md#releases) appends a line with `"kind": "release-rc"`
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
