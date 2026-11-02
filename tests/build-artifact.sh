#!/bin/bash
# Self-test for the rule bin/build-artifact applies (helpers/build-artifact.jq):
# of the artifacts carrying a package's label, the newest one a matching run
# uploaded is reused, and none from any other run.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

REPO=omacom/omarchy-pkgs
# The merged PR's head commit; aaa111 was an earlier commit of the same PR.
HEADS='["aaa222"]'
artifact() { jq -nc --arg id "$1" --arg at "$2" '{archive_download_url: "https://x/\($id).zip", created_at: $at, workflow_run: {id: ($id | tonumber)}}'; }
run() { # run <id> <workflow file> <event> <head sha> <head branch> <head repository>
  jq -nc --arg id "$1" --arg p ".github/workflows/$2" --arg e "$3" --arg s "$4" --arg b "$5" --arg r "$6" \
    '{id: ($id | tonumber), path: $p, event: $e, head_sha: $s, head_branch: $b, head_repository: $r}'
}
pick() { # pick <artifacts...> -- [runs...], as publish.yml asks; PR_REPO/PR_BRANCH set asks as a PR build
  local a=() r=() seen=0 x
  for x in "$@"; do if [[ $x == -- ]]; then seen=1; elif (( seen )); then r+=("$x"); else a+=("$x"); fi; done
  jq -nr --argjson artifacts "$(printf '%s\n' "${a[@]}" | jq -sc .)" --argjson runs "$( (( ${#r[@]} )) && printf '%s\n' "${r[@]}" | jq -sc . || echo '[]')" \
    --argjson heads "$HEADS" --arg repo "$REPO" --arg run_id 900 \
    --arg pr_repo "${PR_REPO:-}" --arg pr_branch "${PR_BRANCH:-}" -f "$ROOT/helpers/build-artifact.jq"
}

# A fork's run uploads under the same name after the merged PR's build did.
got=$(pick "$(artifact 10 2026-10-20T10:00:00Z)" "$(artifact 11 2026-10-20T11:00:00Z)" -- \
  "$(run 10 build-pr.yml pull_request aaa222 fix someone/omarchy-pkgs)" \
  "$(run 11 build-pr.yml pull_request bbb999 other other/omarchy-pkgs)")
[[ $got == "https://x/10.zip 10" ]] && pass "the merged PR's head build counts; a fork's run that did not merge is passed over" || fail "fork run: $got"

got=$(pick "$(artifact 12 2026-10-20T10:00:00Z)" "$(artifact 13 2026-10-20T10:00:00Z)" -- \
  "$(run 12 build-pr.yml pull_request aaa111 fix someone/omarchy-pkgs)" \
  "$(run 13 build-pr.yml pull_request ccc333 auto/sync-x "$REPO")")
[[ -z $got ]] && pass "an earlier commit of the merged PR, or another branch here, never counts" || fail "earlier commit or branch: $got"

got=$(pick "$(artifact 14 2026-10-20T10:00:00Z)" -- "$(run 14 publish.yml push ddd444 master "$REPO")")
[[ $got == "https://x/14.zip 14" ]] && pass "a merge's own rebuild on master counts" || fail "publish on master: $got"

# This run counts as itself, whatever branch it says it ran on.
got=$(pick "$(artifact 900 2026-10-20T10:00:00Z)" -- "$(run 900 publish.yml workflow_dispatch ddd444 elsewhere "$REPO")")
[[ $got == "https://x/900.zip 900" ]] && pass "this run's rebuild counts" || fail "this run: $got"

got=$(pick "$(artifact 15 2026-10-20T10:00:00Z)" "$(artifact 16 2026-10-20T10:00:00Z)" "$(artifact 17 2026-10-20T10:00:00Z)" -- \
  "$(run 15 publish.yml push eee555 feature "$REPO")" \
  "$(run 16 publish.yml push aaa222 master other/omarchy-pkgs)" \
  "$(run 17 other.yml pull_request aaa222 fix "$REPO")")
[[ -z $got ]] && pass "publish.yml off master or from a fork, or another workflow, never counts" || fail "other runs: $got"

got=$(pick "$(artifact 18 2026-10-20T10:00:00Z)" --)
[[ -z $got ]] && pass "an artifact whose run cannot be looked up never counts" || fail "unknown run: $got"

# A PR build reuses only its own branch's earlier builds, whoever else
# uploaded an artifact under the same name.
pr_pick() { PR_REPO=$1 PR_BRANCH=$2 pick "${@:3}"; }
got=$(pr_pick someone/omarchy-pkgs fix "$(artifact 20 2026-10-20T10:00:00Z)" "$(artifact 21 2026-10-20T11:00:00Z)" "$(artifact 22 2026-10-20T12:00:00Z)" -- \
  "$(run 20 build-pr.yml pull_request aaa111 fix someone/omarchy-pkgs)" \
  "$(run 21 build-pr.yml pull_request bbb999 fix other/omarchy-pkgs)" \
  "$(run 22 build-pr.yml pull_request ccc333 other someone/omarchy-pkgs)")
[[ $got == "https://x/20.zip 20" ]] && pass "a PR build reuses its own branch's earlier build only" || fail "PR reuse: $got"

got=$(pr_pick "$REPO" auto/sync-x "$(artifact 23 2026-10-20T10:00:00Z)" "$(artifact 24 2026-10-20T11:00:00Z)" -- \
  "$(run 23 publish.yml push ddd444 master "$REPO")" \
  "$(run 24 other.yml pull_request eee555 auto/sync-x "$REPO")")
[[ -z $got ]] && pass "a PR build never reuses another workflow's artifact, even on its own branch" || fail "PR reuse, other workflow: $got"
