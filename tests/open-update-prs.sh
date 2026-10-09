#!/bin/bash
# The tracker opens one PR per package, keeps branch followers together, does
# not restart a build for an update already proposed, and tidies up after
# itself without closing a PR that still has something to merge.
set -euo pipefail
BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

git init --quiet --bare -b master "$T/origin.git"
git init --quiet -b master "$T/repo"
cd "$T/repo"
mkdir -p .github/scripts
cp "$BUILD_ROOT/.github/scripts/open-update-prs.sh" .github/scripts/
printf 'build-output/\n*.pkg.tar.zst\n' > .gitignore

recipe() { # recipe <name> <version> [metadata]
  mkdir -p "pkgbuilds/$1/.omarchy"
  printf 'pkgname=%s\npkgver=%s\npkgrel=1\n' "$1" "$2" > "pkgbuilds/$1/PKGBUILD"
  printf '%s\n' "${3:-{\"source\":\"local\",\"auto_merge\":true\}}" > "pkgbuilds/$1/.omarchy/package.json"
}
follows='{"source":"local","auto_merge":true,"upstream":{"watch":{"git_branch":"https://example.com/app.git","branch":"main"}}}'
recipe alpha 1.0
recipe beta 1.0
recipe gamma 1.0
recipe app-dev 1.0 "$follows"
recipe app-settings-dev 1.0 "$follows"
git add -A && git commit --quiet -m base
git push --quiet "$T/origin.git" master

# A stand-in for gh: pull requests are files under $T/prs, one per branch.
mkdir -p "$T/bin" "$T/prs"
cat > "$T/bin/gh" <<'GH'
#!/bin/bash
set -euo pipefail
echo "gh $*" >> "$GH_LOG"
arg() { local want=$1; shift; while (( $# )); do [[ $1 == "$want" ]] && { echo "$2"; return; }; shift; done; }
slug() { tr '/' '_' <<<"$1"; }
by_number() { grep -lx "number=$1" "$GH_PRS"/*/meta | head -1 | xargs -r dirname; }
files_of() { # what the PR changes: recorded, or read off its branch
  if [[ -f "$1/files" ]]; then cat "$1/files"
  else git --git-dir="$GH_ORIGIN" diff --name-only "master...$(cat "$1/branch")"; fi
}
case "$1 $2" in
  "pr list")
    d="$GH_PRS/$(slug "$(arg --head "$@")")"
    [[ -f "$d/meta" && "$(cat "$d/state")" == open ]] || exit 0
    echo "$(sed -n 's/^number=//p' "$d/meta") $(cat "$d/mergeable")" ;;
  "pr create")
    d="$GH_PRS/$(slug "$(arg --head "$@")")"; mkdir -p "$d"
    n=$(( $(cat "$GH_PRS/next" 2>/dev/null || echo 100) + 1 )); echo "$n" > "$GH_PRS/next"
    echo "number=$n" > "$d/meta"; echo open > "$d/state"; echo MERGEABLE > "$d/mergeable"; echo false > "$d/auto"
    arg --head "$@" > "$d/branch"
    arg --title "$@" > "$d/title"
    echo "https://github.com/o/r/pull/$n" ;;
  "pr edit") arg --title "$@" > "$(by_number "$3")/title" ;;
  "pr view")
    d=$(by_number "$3")
    case "$(arg --json "$@")" in
      autoMergeRequest) cat "$d/auto" ;;
    esac ;;
  "api --paginate")
    [[ -z "${GH_FAIL_FILES:-}" ]] || exit 1
    n=${3%/files}; files_of "$(by_number "${n##*/}")" ;;
  "pr merge") echo true > "$(by_number "$5")/auto" ;;
  "pr close") echo closed > "$(by_number "$3")/state" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
GH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" GH_PRS="$T/prs" GH_ORIGIN="$T/origin.git"
export GH_TOKEN=test GITHUB_REPOSITORY=o/r PUSH_REMOTE="$T/origin.git"

bump() { sed -i "s/^pkgver=.*/pkgver=$2/" "pkgbuilds/$1/PKGBUILD"; }
run() { : > "$GH_LOG"; .github/scripts/open-update-prs.sh "$@" > "$T/out" 2>&1 || { cat "$T/out"; echo "FAIL: script exited non-zero"; exit 1; }; }
branches() { git --git-dir="$T/origin.git" for-each-ref --format='%(refname:short)' refs/heads/auto | paste -sd' '; }
changed() { git --git-dir="$T/origin.git" diff --name-only master "$1" | paste -sd' '; }
tip() { git --git-dir="$T/origin.git" rev-parse "$1"; }
expect() { [[ "$2" == "$3" ]] || { printf 'FAIL: %s\n  expected: %s\n  got:      %s\n' "$1" "$2" "$3"; cat "$T/out"; exit 1; }; }

# --- one PR per package; branch followers share one ------------------------
bump alpha 2.0; bump beta 2.0; bump app-dev 2.0; bump app-settings-dev 2.0
touch pkgbuilds/alpha/alpha-2.0-1-any.pkg.tar.zst   # ignored build output
run
expect "a branch per package, followers together" \
  "auto/track/alpha auto/track/app-dev auto/track/beta" "$(branches)"
expect "alpha's branch carries only alpha" "pkgbuilds/alpha/PKGBUILD" "$(changed auto/track/alpha)"
expect "followers of one branch travel together" \
  "pkgbuilds/app-dev/PKGBUILD pkgbuilds/app-settings-dev/PKGBUILD" "$(changed auto/track/app-dev)"
expect "titles name the package and version" "Update alpha to 2.0" "$(cat "$T/prs/auto_track_alpha/title")"
expect "a shared PR names every member" \
  "Update app-dev to 2.0, app-settings-dev to 2.0" "$(cat "$T/prs/auto_track_app-dev/title")"
expect "auto-merge is enabled on each" "true true true" \
  "$(cat "$T"/prs/auto_track_{alpha,app-dev,beta}/auto | paste -sd' ')"
expect "the working tree is left as the sync wrote it" "2.0" "$(sed -n 's/^pkgver=//p' pkgbuilds/alpha/PKGBUILD)"
echo "PASS: one PR per package, branch followers together, auto-merge on each"

# --- a second run with the same updates restarts nothing -------------------
# A second later, so a commit made again would get a different id.
before=$(tip auto/track/alpha)
sleep 1
run
expect "an update already proposed is not pushed again" "$before" "$(tip auto/track/alpha)"
expect "and no second PR is opened" "0" "$(grep -c 'pr create' "$GH_LOG" || true)"

# A newer release replaces the proposal in the same PR.
bump alpha 3.0
run
[[ "$(tip auto/track/alpha)" != "$before" ]] || { echo "FAIL: a newer release must update the branch"; exit 1; }
expect "the same PR is retitled" "Update alpha to 3.0" "$(cat "$T/prs/auto_track_alpha/title")"
expect "still one PR for alpha" "0" "$(grep -c 'pr create' "$GH_LOG" || true)"

# A PR that no longer merges is pushed again on the current base.
echo CONFLICTING > "$T/prs/auto_track_beta/mergeable"
before=$(tip auto/track/beta)
echo "logs/" >> .gitignore
git commit --quiet -m "master moves" -- .gitignore
git push --quiet "$T/origin.git" master
run
[[ "$(tip auto/track/beta)" != "$before" ]] || { echo "FAIL: a conflicting PR must be rebuilt on the new base"; exit 1; }
echo MERGEABLE > "$T/prs/auto_track_beta/mergeable"

# A branch that picked up a change outside its package is rebuilt clean.
git worktree add --quiet --detach "$T/extra" "$(tip auto/track/alpha)"
echo stray > "$T/extra/stray.txt"; git -C "$T/extra" add stray.txt
git -C "$T/extra" commit --quiet -m "stray change"
git -C "$T/extra" push --quiet --force "$T/origin.git" HEAD:refs/heads/auto/track/alpha
git worktree remove --force "$T/extra"
run
expect "a branch carrying anything but its package is pushed again" \
  "pkgbuilds/alpha/PKGBUILD" "$(changed auto/track/alpha)"
echo "PASS: unchanged proposals are left alone; newer, conflicting and polluted ones are refreshed"

# --- tidying up ------------------------------------------------------------
# beta merged: master has 2.0, and this run finds nothing to update for it.
git commit --quiet -m "merge beta 2.0" -- pkgbuilds/beta
git push --quiet "$T/origin.git" master
# gamma and delta each have an open PR master does not have, and their feeds
# fail this run: nothing changes in the working tree for them.
leftover() { # leftover <name> <pr number>
  git worktree add --quiet --detach "$T/$1" HEAD
  sed -i 's/^pkgver=.*/pkgver=5.0/' "$T/$1/pkgbuilds/$1/PKGBUILD"
  git -C "$T/$1" commit --quiet -am "$1 5.0"
  git -C "$T/$1" push --quiet --force "$T/origin.git" "HEAD:refs/heads/auto/track/$1"
  git worktree remove --force "$T/$1"
  mkdir -p "$T/prs/auto_track_$1"
  echo "number=$2" > "$T/prs/auto_track_$1/meta"; echo open > "$T/prs/auto_track_$1/state"
  echo MERGEABLE > "$T/prs/auto_track_$1/mergeable"; echo true > "$T/prs/auto_track_$1/auto"
  echo "auto/track/$1" > "$T/prs/auto_track_$1/branch"
}
recipe delta 1.0; git add -A pkgbuilds/delta; git commit --quiet -m "add delta" -- pkgbuilds/delta
git push --quiet "$T/origin.git" master
leftover gamma 900
leftover delta 901
echo CONFLICTING > "$T/prs/auto_track_delta/mergeable"
# The shared PR from before the split.
git push --quiet "$T/origin.git" HEAD:refs/heads/auto/track-branches
mkdir -p "$T/prs/auto_track-branches"
echo "number=950" > "$T/prs/auto_track-branches/meta"; echo open > "$T/prs/auto_track-branches/state"
echo MERGEABLE > "$T/prs/auto_track-branches/mergeable"; echo auto/track-branches > "$T/prs/auto_track-branches/branch"

run --scoped
expect "a scoped run tidies nothing" "open open" \
  "$(cat "$T/prs/auto_track_beta/state" "$T/prs/auto_track-branches/state" | paste -sd' ')"

GH_FAIL_FILES=1 run
expect "a PR that could not be inspected is kept" "open" "$(cat "$T/prs/auto_track_beta/state")"
case " $(branches) " in *" auto/track/beta "*) ;; *) echo "FAIL: beta's branch must survive a failed lookup"; exit 1 ;; esac

run
expect "a PR master has caught up with is closed" "closed" "$(cat "$T/prs/auto_track_beta/state")"
case " $(branches) " in *" auto/track/beta "*) echo "FAIL: beta's branch should be deleted"; exit 1 ;; esac
expect "a PR that still merges and still differs stays open" "open" "$(cat "$T/prs/auto_track_gamma/state")"
case " $(branches) " in *" auto/track/gamma "*) ;; *) echo "FAIL: gamma's branch must survive"; exit 1 ;; esac
expect "a PR that can no longer merge is closed" "closed" "$(cat "$T/prs/auto_track_delta/state")"
expect "the old shared PR is closed" "closed" "$(cat "$T/prs/auto_track-branches/state")"
case " $(branches) " in *" auto/track-branches "*) echo "FAIL: the old shared branch should be deleted"; exit 1 ;; esac
echo "PASS: finished and dead PRs are tidied; live and uninspectable ones are kept"
