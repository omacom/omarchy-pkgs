#!/bin/bash
# Usage: should-push-pr.sh BRANCH PACKAGE...
#
# Run by package-prs.yml after the group's changes are applied to the working
# tree, before hold-reviewed-pr.sh and peter-evans/create-pull-request.
#
# Stops scheduled runs from force-pushing a fresh rebased commit onto an
# already-open PR when nothing in its packages changed (cutting repeated builds
# on broken PRs from every 6 hours to a weekly retry) and prevents overwriting
# a maintainer's manual fix commit pushed directly onto the PR branch while
# upstream has not moved past the bot's original commit.
#
# Still refreshes immediately when:
# - upstream produces any different package tree (new version, revision, hash,
#   rebuilt_against, or a recipe fix landed on master);
# - the PR conflicts with base (and carries no protected maintainer commit);
# - checks never started or ended in a transient status (TIMED_OUT, CANCELLED,
#   STARTUP_FAILURE); or
# - the PR head commit is older than RETRY_AFTER_SECONDS (default 7 days), so
#   toolchain or shared-infra fixes on master still get re-tested periodically.
#
# Prints key=value lines suitable for $GITHUB_OUTPUT:
#   push=true|false
#   pr=<number or empty>
#   reason=new|updated|conflict|transient-check|stale-retry|unchanged|human-commit
set -euo pipefail

branch=${1:?branch required}
shift
(( $# > 0 )) || { echo "should-push-pr.sh: packages required" >&2; exit 2; }
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}
base=${DEFAULT_BRANCH:-master}
bot_login=${SYNC_BOT_LOGIN:-omarchy-pkgs-sync}
retry_after=${RETRY_AFTER_SECONDS:-604800}

emit() {
  printf "push=%s\npr=%s\nreason=%s\n" "$1" "$2" "$3"
}

# Only this repository's open PR targeting base.
pr=$(gh api -X GET "repos/$repo/pulls" -f head="${repo%%/*}:$branch" -f base="$base" -f state=open \
  --jq '.[0].number // empty')
if [[ -z $pr ]]; then
  emit true "" new
  exit 0
fi

IFS='|' read -r mergeable commit_count first_oid tip_oid tip_author tip_date check_state < <(
  # shellcheck disable=SC2016
  gh pr view "$pr" -R "$repo" --json mergeable,commits,statusCheckRollup \
    --jq '[
      (.mergeable // "UNKNOWN"),
      (.commits | length | tostring),
      (.commits[0].oid // ""),
      (.commits[-1].oid // ""),
      (.commits[-1].authors[0].login // ""),
      (.commits[-1].committedDate // ""),
      (
        (.statusCheckRollup // []) as $r |
        if ($r | length) == 0 then "NONE"
        elif any($r[]; (.conclusion // "") | IN("TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "STALE")) then "TRANSIENT"
        else "SETTLED"
        end
      )
    ] | join("|")'
)

paths=()
for package in "$@"; do paths+=("pkgbuilds/$package"); done

# Stage pkgbuilds/<pkg>/ (including newly added untracked files) into a
# throwaway index and compare that candidate tree against FETCH_HEAD so both
# newly added files and already-present added files compare accurately.
tree_matches_fetch_head() {
  local tmp_index rc=0
  tmp_index=$(mktemp)
  GIT_INDEX_FILE="$tmp_index" git read-tree HEAD &&
    GIT_INDEX_FILE="$tmp_index" git add -A -- "${paths[@]}" &&
    GIT_INDEX_FILE="$tmp_index" git diff --cached --quiet FETCH_HEAD -- "${paths[@]}" || rc=$?
  rm -f "$tmp_index"
  return "$rc"
}

# Check for maintainer commits BEFORE handling conflicts so a conflict on master
# never wipes out a human fix commit pushed onto the PR branch. An empty
# tip_author (unlinked git email) is treated as non-bot, and a failed fetch of
# the bot's original commit preserves the branch rather than overwriting it.
if (( commit_count > 1 )) && [[ $tip_author != "$bot_login" && $tip_author != "app/$bot_login" ]]; then
  if [[ -z $first_oid ]] || ! git fetch --quiet --no-tags --depth=1 origin "$first_oid"; then
    emit false "$pr" human-commit
    exit 0
  fi
  if tree_matches_fetch_head; then
    emit false "$pr" human-commit
    exit 0
  fi
fi

# A conflicting PR (with no protected maintainer work) must refresh onto base.
if [[ $mergeable == CONFLICTING ]]; then
  emit true "$pr" conflict
  exit 0
fi

# Fetch the exact tip commit inspected above rather than re-reading the moving
# branch ref, avoiding a race with a maintainer push arriving mid-check.
fetch_ref=${tip_oid:-refs/heads/$branch}
if ! git fetch --quiet --no-tags --depth=1 origin "$fetch_ref"; then
  emit true "$pr" updated
  exit 0
fi

# Any difference in pkgbuilds/<pkg>/ (new upstream release, revision, checksum,
# rebuilt_against, new file, or a recipe fix that landed on master) refreshes the PR.
if ! tree_matches_fetch_head; then
  emit true "$pr" updated
  exit 0
fi

# Identical package files, but checks never registered or hit a transient infra failure.
if [[ $check_state == NONE || $check_state == TRANSIENT ]]; then
  emit true "$pr" transient-check
  exit 0
fi

# Periodic retry so Arch repo or shared-tooling fixes on master re-test old PRs.
if [[ -n $tip_date ]] && tip_epoch=$(date --date="$tip_date" +%s 2>/dev/null); then
  now=$(date +%s)
  if (( now - tip_epoch >= retry_after )); then
    emit true "$pr" stale-retry
    exit 0
  fi
fi

emit false "$pr" unchanged
