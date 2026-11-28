#!/bin/bash
# Usage: hold-reviewed-pr.sh BRANCH PACKAGE...
#
# Run by package-prs.yml for a reviewed group (a package with "review": true)
# after the group's changes are applied to the working tree, before anything
# is pushed to BRANCH. An open PR there that the owner already marked ready, or
# that auto-merge-pr.yml armed, must not take a new update unreviewed: turn it
# back into a draft, disable auto-merge, and read both back. Exits non-zero,
# so nothing is pushed, if either still holds.
#
# A PR whose branch already carries these packages exactly as the working tree
# has them is left alone, so a rerun or a rebase onto a newer master doesn't
# undo a review of the same update. Needs GH_TOKEN and GITHUB_REPOSITORY.
set -euo pipefail

branch=${1:?branch required}
shift
(( $# > 0 )) || { echo "hold-reviewed-pr.sh: packages required" >&2; exit 2; }
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}

# Only this repository's PR into master. GitHub filters by owner:branch
# itself: a client-side filter after a page limit could miss ours behind
# forks' PRs from a branch of the same name. A failed lookup stops the push.
pr=$(gh api -X GET "repos/$repo/pulls" -f head="${repo%%/*}:$branch" -f base=master -f state=open \
  --jq '.[0].number // empty')
if [[ -z $pr ]]; then
  echo "no open PR on $branch: it opens as a draft"
  exit 0
fi

paths=()
for package in "$@"; do paths+=("pkgbuilds/$package"); done
if git fetch --quiet --no-tags --depth=1 origin "refs/heads/$branch" &&
  git diff --quiet FETCH_HEAD -- "${paths[@]}"; then
  echo "#$pr already carries this update: left as it is"
  exit 0
fi

state() { gh pr view "$pr" -R "$repo" --json isDraft,autoMergeRequest --jq '"\(.isDraft) \(.autoMergeRequest != null)"'; }
read -r draft armed <<<"$(state)"
if [[ $armed != false ]]; then gh pr merge --disable-auto "$pr" -R "$repo"; fi
if [[ $draft != true ]]; then gh pr ready --undo "$pr" -R "$repo"; fi

read -r draft armed <<<"$(state)"
if [[ $draft != true || $armed != false ]]; then
  echo "::error::#$pr is still draft=$draft auto-merge=$armed: not pushing a new update to it"
  exit 1
fi
echo "#$pr is back to a draft with auto-merge off before its update is pushed"
