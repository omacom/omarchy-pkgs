# Operating the pipeline

Tasks for maintainers: republish, build, retire, verify, and recover a failed publish.

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

### Check that a version is live

What the recipe says, from an up-to-date checkout of `master` (`<recipe>` is
the directory name under `pkgbuilds/`):

```bash
bin/repo list --json | jq -r '.[] | select(.name == "<recipe>") | .version'
bin/repo list                                   # Every recipe, as a table
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

A publish run appends one JSON line to
`https://pkgs.omarchy.org/publish-log.jsonl` when it finishes, newest last.
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
wrote no channel.

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
  select(any(.sources[]; .source | test("failed")) or any(.slots[]; .status == "failed"))
  | {time, run, failed: [.sources[] | select(.source | test("failed")) | "\(.package) \(.arch) \(.source)"]}'
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
| `publish`, step "Publish" | `Upload incomplete`, or an rclone or gpg error | Storage or signing trouble. Rerun: `gh run rerun <run-id> --failed` |
| `publish` shows cancelled, and nobody cancelled it | | GitHub keeps one publish waiting at a time; when several merges land close together it cancels the ones in between. Republish their packages with a dispatch |

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
