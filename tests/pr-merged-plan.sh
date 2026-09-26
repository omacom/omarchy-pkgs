#!/bin/bash
# The PR planner must see the change a PR would merge, not the changes that
# arrived on master while the PR waited for review.
set -euo pipefail
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
repo="$T/repo"
mkdir -p "$repo/pkgbuilds/alpha" "$repo/pkgbuilds/beta"
printf 'alpha=old\n' > "$repo/pkgbuilds/alpha/PKGBUILD"
printf 'beta=old\n' > "$repo/pkgbuilds/beta/PKGBUILD"
git -C "$repo" init -q -b master
commit() { git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.test commit -qam "$1"; }
git -C "$repo" add .; commit initial

git -C "$repo" switch -q -c feature
printf 'alpha=feature\n' > "$repo/pkgbuilds/alpha/PKGBUILD"
printf 'new tooling\n' > "$repo/build-tool"
git -C "$repo" add .; commit feature
head=$(git -C "$repo" rev-parse HEAD)

git -C "$repo" switch -q master
printf 'beta=master\n' > "$repo/pkgbuilds/beta/PKGBUILD"
git -C "$repo" add .; commit master
tree=$(git -C "$repo" merge-tree --write-tree HEAD "$head")
changed=$(git -C "$repo" diff --name-only HEAD "$tree" -- pkgbuilds)
[[ "$changed" == 'pkgbuilds/alpha/PKGBUILD' ]] || {
  echo "FAIL: current master package changes entered the PR plan: $changed" >&2; exit 1;
}
git -C "$repo" restore --source="$tree" --staged --worktree -- pkgbuilds/
[[ $(cat "$repo/pkgbuilds/alpha/PKGBUILD") == 'alpha=feature' ]]
[[ $(cat "$repo/pkgbuilds/beta/PKGBUILD") == 'beta=master' ]]
index_tree=$(git -C "$repo" write-tree)
[[ $(git -C "$repo" rev-parse "$tree:pkgbuilds/alpha") == $(git -C "$repo" rev-parse "$index_tree:pkgbuilds/alpha") ]]
echo 'PASS: aged PR plan and build retain current master changes'
