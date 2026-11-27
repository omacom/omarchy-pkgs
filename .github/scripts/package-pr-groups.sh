#!/bin/bash
# Usage: package-pr-groups.sh BRANCH_PREFIX PATCH_OUT
#
# Run from the repository root after a sync has rewritten recipes in the
# working tree. Writes those changes to PATCH_OUT and prints, as one JSON
# line, the PRs they split into: [{"branch": ..., "packages": "a b"}, ...].
#
# One PR per package, so a package whose build fails holds back only itself.
# A group holding a package marked "review": true carries "review": true, and
# package-prs.yml opens it as a draft without arming auto-merge.
# Packages pinned from the same upstream branch (omarchy-dev and
# omarchy-settings-dev) share a PR: sync-upstream moves them in lockstep, and
# merging one without the other would ship the pair from different commits.
# So do packages naming the same "lockstep" group, such as the NVIDIA driver
# and the kernels that build its modules: bin/bump-nvidia moves them together.
# Branch names come from sync-pr-branch.sh, so a scheduled run and a dispatch
# naming the same packages update the same PR.
set -euo pipefail

prefix=${1:?branch prefix required}
patch=${2:?patch path required}
scripts=$(dirname "$0")

git diff --binary -- pkgbuilds > "$patch"

declare -A members=() review=()
while IFS= read -r package; do
  key=$(jq -r '(.lockstep | strings | "lockstep:\(.)") // (.upstream.watch? | objects | select(has("git_branch")) | "\(.git_branch)#\(.branch)") // empty' \
    "pkgbuilds/$package/.omarchy/package.json" 2>/dev/null || true)
  members["${key:-$package}"]+="$package "
  if [[ $(jq -r '.review == true' "pkgbuilds/$package/.omarchy/package.json" 2>/dev/null) == true ]]; then
    review["${key:-$package}"]=1
  fi
done < <(git diff --name-only -- pkgbuilds | cut -d/ -f2 | sort -u)

groups='[]'
for key in "${!members[@]}"; do
  read -r -a packages <<<"${members[$key]}"
  branch=$("$scripts/sync-pr-branch.sh" "$prefix" "${packages[@]}" | sed -n 's/^branch=//p')
  groups=$(jq -c --arg branch "$branch" --arg packages "${packages[*]}" --arg review "${review[$key]:-}" \
    '. + [{branch: $branch, packages: $packages} + (if $review == "" then {} else {review: true} end)]' <<<"$groups")
done
jq -c 'sort_by(.branch)' <<<"$groups"
