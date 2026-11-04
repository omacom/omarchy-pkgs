#!/bin/bash
# Usage: package-pr-groups.sh BRANCH_PREFIX PATCH_OUT
#
# Run from the repository root after a sync has rewritten recipes in the
# working tree. Writes those changes to PATCH_OUT and prints, as one JSON
# line, the PRs they split into: [{"branch": ..., "packages": "a b"}, ...].
#
# One PR per package, so a package whose build fails holds back only itself.
# Packages pinned from the same upstream branch (omarchy-dev and
# omarchy-settings-dev) share a PR: sync-upstream moves them in lockstep, and
# merging one without the other would ship the pair from different commits.
# Branch names come from sync-pr-branch.sh, so a scheduled run and a dispatch
# naming the same packages update the same PR.
set -euo pipefail

prefix=${1:?branch prefix required}
patch=${2:?patch path required}
scripts=$(dirname "$0")

git diff --binary -- pkgbuilds > "$patch"

declare -A members=()
while IFS= read -r package; do
  key=$(jq -r '(.upstream.watch? | objects | select(has("git_branch")) | "\(.git_branch)#\(.branch)") // empty' \
    "pkgbuilds/$package/.omarchy/package.json" 2>/dev/null || true)
  members["${key:-$package}"]+="$package "
done < <(git diff --name-only -- pkgbuilds | cut -d/ -f2 | sort -u)

groups='[]'
for key in "${!members[@]}"; do
  read -r -a packages <<<"${members[$key]}"
  branch=$("$scripts/sync-pr-branch.sh" "$prefix" "${packages[@]}" | sed -n 's/^branch=//p')
  groups=$(jq -c --arg branch "$branch" --arg packages "${packages[*]}" \
    '. + [{branch: $branch, packages: $packages}]' <<<"$groups")
done
jq -c 'sort_by(.branch)' <<<"$groups"
