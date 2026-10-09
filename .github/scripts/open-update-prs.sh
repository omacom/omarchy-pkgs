#!/bin/bash
# Turn the working tree's package updates into one pull request per package.
#
#   open-update-prs.sh [--scoped]
#
# Run after bin/sync-upstream has rewritten recipes under pkgbuilds/. Every
# changed package gets its own branch, auto/track/<package>, cut from HEAD and
# carrying only that package's change, and its own PR with auto-merge enabled.
# One upstream that fails to build then holds back only itself.
#
# Packages pinned from the same upstream branch (a git_branch watch) are the
# exception: they move together or not at all, so they share one branch and
# PR, named after the first of them.
#
# A branch whose PR already carries exactly this update, and nothing else, is
# left alone, so a tracker run does not restart a build that is in flight.
#
# A leftover branch, one this run found no update for, is tidied up: deleted
# when it has no open PR, and its PR closed when master already holds what the
# PR changes or the PR can no longer merge. An open PR that still merges and
# still differs from master is kept, because a feed that failed to answer
# looks the same as one with nothing new. So is any PR the script could not
# inspect. --scoped skips the tidying: a run for named packages says nothing
# about the others.
#
# Environment:
#   GH_TOKEN            a token whose pushes and merges start workflows
#   GITHUB_REPOSITORY   owner/name
#   BASE_BRANCH         branch PRs target (default: master)
#   BRANCH_PREFIX       default: auto/track
#   PUSH_REMOTE         git remote or URL to push to (default: built from the
#                       two variables above)
set -euo pipefail

SCOPED=false
[[ "${1:-}" != --scoped ]] || SCOPED=true

: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}"
BASE_BRANCH=${BASE_BRANCH:-master}
BRANCH_PREFIX=${BRANCH_PREFIX:-auto/track}
# The single branch every update shared before there was one per package.
LEGACY_BRANCH=${LEGACY_BRANCH:-auto/track-branches}
PUSH_REMOTE=${PUSH_REMOTE:-https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git}
BOT_NAME='github-actions[bot]'
BOT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
WORK=$(mktemp -d)
trap 'git worktree remove --force "$WORK/tree" 2>/dev/null || true; rm -rf "$WORK"' EXIT

# "<repository>#<branch>" for a package that follows a branch, else nothing.
branch_watch_key() {
  jq -r '(.upstream.watch? | objects | select(has("git_branch"))) | "\(.git_branch)#\(.branch)"' \
    "pkgbuilds/$1/.omarchy/package.json" 2>/dev/null || true
}

# The group a package belongs to: itself, or for a branch follower the first
# (in sort order) of every package following that branch.
declare -A KEY_GROUP=()
for dir in pkgbuilds/*/; do
  name=$(basename "$dir")
  key=$(branch_watch_key "$name")
  [[ -n "$key" ]] || continue
  [[ -n "${KEY_GROUP[$key]:-}" ]] || KEY_GROUP[$key]=$name
done
group_of() {
  local key
  key=$(branch_watch_key "$1")
  if [[ -n "$key" ]]; then echo "${KEY_GROUP[$key]}"; else echo "$1"; fi
}

# Changed package directories, grouped.
declare -A MEMBERS=()
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  group=$(group_of "$name")
  MEMBERS[$group]+="$name "
done < <(git status --porcelain --untracked-files=all -- pkgbuilds |
  sed -E 's/^.{3}//; s/^.* -> //; s/^"//; s/"$//' | awk -F/ '$1=="pkgbuilds" && NF>2 {print $2}' | sort -u)

git fetch --quiet --prune --depth=1 "$PUSH_REMOTE" "+refs/heads/$BRANCH_PREFIX/*:refs/remotes/update-prs/*" 2>/dev/null || true

open_pr() { # open_pr <branch>: number and mergeable state of its open PR, or nothing
  gh pr list -R "$GITHUB_REPOSITORY" --head "$1" --base "$BASE_BRANCH" --state open \
    --json number,mergeable --jq '.[0] | select(. != null) | "\(.number) \(.mergeable)"'
}

pr_files() { # pr_files <number>: every path the PR changes, one per line
  # Both ends of a rename: a file moved out of somewhere changes that place too.
  gh api --paginate "repos/$GITHUB_REPOSITORY/pulls/$1/files" \
    --jq '.[] | .filename, (.previous_filename // empty)'
}

# True when every path on stdin lies under one of the given directories.
only_under() {
  local file dir inside
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    inside=false
    for dir in "$@"; do [[ "$file" == "$dir"/* ]] && inside=true; done
    [[ $inside == true ]] || return 1
  done
}

failed=0
for group in $(printf '%s\n' "${!MEMBERS[@]}" | sort); do
  read -r -a members <<<"${MEMBERS[$group]}"
  branch="$BRANCH_PREFIX/$group"
  paths=(); for m in "${members[@]}"; do paths+=("pkgbuilds/$m"); done

  # "gliff to 0.3.0", from the pkgver line the sync rewrote.
  moved=()
  for m in "${members[@]}"; do
    version=$(git diff --unified=0 -- "pkgbuilds/$m/PKGBUILD" | sed -nE 's/^\+pkgver=//p' | head -1 | tr -d "\"'")
    moved+=("$m${version:+ to $version}")
  done
  title="Update $(IFS=,; echo "${moved[*]}" | sed 's/,/, /g')"

  # This group's change alone, on top of HEAD.
  git worktree remove --force "$WORK/tree" 2>/dev/null || true
  git worktree add --quiet --detach "$WORK/tree" HEAD
  for path in "${paths[@]}"; do
    rm -rf "$WORK/tree/$path"
    mkdir -p "$WORK/tree/$path"
    # Tracked and untracked files as they stand; ignored build output stays.
    git ls-files --cached --others --exclude-standard -z -- "$path" |
      while IFS= read -r -d '' file; do
        # -L as well: a tracked symlink whose target is missing still exists.
        [[ -e "$file" || -L "$file" ]] || continue
        mkdir -p "$WORK/tree/$(dirname "$file")"
        cp -a "$file" "$WORK/tree/$file"
      done
  done
  git -C "$WORK/tree" add --all -- "${paths[@]}"
  if git -C "$WORK/tree" diff --cached --quiet; then
    continue
  fi
  git -C "$WORK/tree" -c user.name="$BOT_NAME" -c user.email="$BOT_EMAIL" commit --quiet -m "$title"

  pr=$(open_pr "$branch") || { echo "::error::$group: could not list pull requests"; failed=1; continue; }
  read -r number mergeable <<<"$pr" || true

  # Same update already proposed, it still merges, and the PR changes nothing
  # besides this package: leave its build alone.
  if [[ -n "${number:-}" && "$mergeable" != CONFLICTING ]] &&
     git rev-parse --verify --quiet "refs/remotes/update-prs/$group" >/dev/null &&
     git diff --quiet "refs/remotes/update-prs/$group" "$(git -C "$WORK/tree" rev-parse HEAD)" -- "${paths[@]}" &&
     files=$(pr_files "$number") && only_under "${paths[@]}" <<<"$files"; then
    echo "==> $group: #$number already carries this update"
  else
    if ! git -C "$WORK/tree" push --quiet --force "$PUSH_REMOTE" "HEAD:refs/heads/$branch"; then
      echo "::error::$group: could not push $branch"; failed=1; continue
    fi
    if [[ -z "${number:-}" ]]; then
      body="Automated update on the unattended lane (\`\"auto_merge\": true\` in \`.omarchy/package.json\`).

This PR merges itself once the build checks pass. A failing build leaves it open; the next tracker run replaces it with the newer release or tip."
      if ! url=$(gh pr create -R "$GITHUB_REPOSITORY" --head "$branch" --base "$BASE_BRANCH" \
            --title "$title" --body "$body" --label automated); then
        echo "::error::$group: could not open a pull request"; failed=1; continue
      fi
      number=${url##*/}
      echo "==> $group: opened #$number ($title)"
    else
      gh pr edit "$number" -R "$GITHUB_REPOSITORY" --title "$title" >/dev/null || true
      echo "==> $group: updated #$number ($title)"
    fi
  fi

  # Auto-merge, not a direct merge: branch protection still has to see the
  # required checks green. Enabling it twice is an error, so ask first.
  # auto-merge-pr.yml arms these PRs too and may get there first, so a failure
  # here only counts when the PR is still unarmed afterwards.
  armed() { [[ "$(gh pr view "$number" -R "$GITHUB_REPOSITORY" --json autoMergeRequest --jq '.autoMergeRequest != null')" == true ]]; }
  if ! armed && ! gh pr merge --auto --merge "$number" -R "$GITHUB_REPOSITORY" && ! armed; then
    echo "::error::$group: could not enable auto-merge on #$number"; failed=1
  fi
done

# Leftover branches: ones this run opened or refreshed nothing for.
if [[ $SCOPED == false ]]; then
  while IFS= read -r ref; do
    group=${ref#refs/remotes/update-prs/}
    [[ -z "${MEMBERS[$group]:-}" ]] || continue
    branch="$BRANCH_PREFIX/$group"
    pr=$(open_pr "$branch") || { echo "::warning::$group: could not list pull requests, leaving $branch"; continue; }
    read -r number mergeable <<<"$pr" || true
    if [[ -n "${number:-}" ]]; then
      files=$(pr_files "$number") || { echo "::warning::$group: could not read #$number, leaving it open"; continue; }
      mapfile -t touched <<<"$files"
      if [[ -z "$files" ]]; then
        why="it changes nothing"
      elif git diff --quiet HEAD "$ref" -- "${touched[@]}"; then
        why="$BASE_BRANCH already has this update"
      elif [[ "$mergeable" == CONFLICTING ]]; then
        why="$BASE_BRANCH has moved past it"
      else
        echo "==> $group: #$number still has something to merge, leaving it open"
        continue
      fi
      gh pr close "$number" -R "$GITHUB_REPOSITORY" --comment "Closed by the tracker: $why." >/dev/null ||
        { echo "::warning::$group: could not close #$number"; continue; }
      echo "==> $group: closed #$number, $why"
    fi
    git push --quiet "$PUSH_REMOTE" ":refs/heads/$branch" || echo "::warning::$group: could not delete $branch"
  done < <(git for-each-ref --format='%(refname)' refs/remotes/update-prs/)

  # The old shared branch, once: per-package PRs replace it.
  if pr=$(open_pr "$LEGACY_BRANCH"); then
    read -r number _ <<<"$pr" || true
    if [[ -z "${number:-}" ]] || gh pr close "$number" -R "$GITHUB_REPOSITORY" \
         --comment "Closed by the tracker: each package now gets its own pull request." >/dev/null; then
      [[ -z "${number:-}" ]] || echo "==> closed #$number on $LEGACY_BRANCH, replaced by one PR per package"
      # Fails quietly once the branch is gone.
      git push --quiet "$PUSH_REMOTE" ":refs/heads/$LEGACY_BRANCH" 2>/dev/null || true
    fi
  fi
fi

exit $failed
