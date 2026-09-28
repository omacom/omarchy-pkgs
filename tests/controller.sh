#!/bin/bash
# Self-test for ci/controller.sh: every decision, no cloud.
#
# The controller's two API functions are overridden with canned responses and
# a recorder, then each scenario asserts which creates and deletes it issued.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")

export REPO=o/r DIGITALOCEAN_TOKEN=x GITHUB_TOKEN=x
export CLOUD_INIT="$ROOT/ci/runner-cloud-init.yaml" LOCK=/tmp/controller-test.lock
CONTROLLER_LIBRARY_ONLY=1 source "$ROOT/ci/controller.sh"

# Calls are recorded to a file: the controller invokes the API functions
# inside command substitutions, and a subshell cannot append to an array.
CALLS_FILE=$(mktemp); trap 'rm -f "$CALLS_FILE"' EXIT
NOW=$(date -u +%FT%TZ)
OLD=$(date -u -d '5 hours ago' +%FT%TZ)

# Scenario state: DROPLETS is "id status created" lines, QUEUED a count,
# BUSY a count.
do_api() {
  local path=$1; shift
  echo "do $path $*" >>"$CALLS_FILE"
  case "$path" in
    droplets\?*) printf '%s\n' "$DROPLETS" | jq -Rs '{droplets: [split("\n")[] | select(length>0) | split(" ") | {id: .[0]|tonumber, status: .[1], created_at: .[2]}]}' ;;
    droplets) echo '{"droplet":{"id":999}}' ;;
    droplets/*) echo '{}' ;;
  esac
}
gh_api() {
  local path=$1; shift
  echo "gh $path $*" >>"$CALLS_FILE"
  case "$path" in
    */actions/runs\?*) jq -nc --argjson n "$QUEUED" '{workflow_runs: [range($n) | {id: .}]}' ;;
    */actions/runs/*/jobs) echo '{"jobs":[{"id":1,"status":"queued","labels":["self-hosted","omarchy-builder"]}]}' ;;
    */actions/runners\?*) jq -nc --argjson n "$BUSY" '{runners: [range($n) | {busy: true, labels: [{name: "omarchy-builder"}]}]}' ;;
    */registration-token) echo '{"token":"T"}' ;;
  esac
}

creates() { grep -c '^do droplets -X POST' "$CALLS_FILE" || true; }
deletes() { grep -c '^do droplets/.* -X DELETE' "$CALLS_FILE" || true; }
run() { : >"$CALLS_FILE"; controller_tick >/dev/null; }
check() { # check <name> <expected creates> <expected deletes>
  local c d; c=$(creates); d=$(deletes)
  if [[ "$c" == "$2" && "$d" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (creates=$c want $2, deletes=$d want $3)"; cat "$CALLS_FILE"; exit 1; fi
}

DROPLETS="" QUEUED=0 BUSY=0; run; check "idle: nothing queued, nothing to reap" 0 0
DROPLETS="" QUEUED=2 BUSY=0; run; check "two queued, none live: create two" 2 0
DROPLETS="1 active $NOW" QUEUED=1 BUSY=1; run; check "one queued, one live but busy: create one" 1 0
DROPLETS="1 active $NOW" QUEUED=1 BUSY=0; run; check "one queued, one live and idle: it will take it" 0 0
DROPLETS="1 off $NOW" QUEUED=0 BUSY=0; run; check "powered-off droplet reaped" 0 1
DROPLETS="1 active $OLD" QUEUED=0 BUSY=0; run; check "over-age droplet reaped even if active" 0 1
DROPLETS=$'1 active '"$NOW"$'\n2 active '"$NOW"$'\n3 active '"$NOW"$'\n4 active '"$NOW" QUEUED=3 BUSY=4; MAX_DROPLETS=4; run; check "at cap: no creates" 0 0
DROPLETS=$'1 active '"$NOW"$'\n2 active '"$NOW" QUEUED=5 BUSY=2; MAX_DROPLETS=3; run; check "cap limits creates to remaining room" 1 0
DROPLETS="1 off $NOW" QUEUED=1 BUSY=0; MAX_DROPLETS=4; run; check "off droplet is not capacity: reaped and replaced" 1 1

# The create body must carry the tag (reaper scope) and substituted user-data.
BODY_FILE=$(mktemp); trap 'rm -f "$CALLS_FILE" "$BODY_FILE"' EXIT
do_api() { if [[ $1 == droplets ]]; then printf '%s' "${*: -1}" >"$BODY_FILE"; echo '{"droplet":{"id":1}}'; else echo '{"droplets":[]}'; fi; }
gh_api() { echo '{"token":"TOK"}'; }
create_droplet >/dev/null
jq -e '.tags == ["omarchy-builder"] and .size == "g5-32vcpu-64gb-50gb" and (.user_data | test("--token \"TOK\"")) and (.user_data | test("__") | not)' "$BODY_FILE" >/dev/null \
  && echo "PASS: create body carries tag, size, substituted user-data" \
  || { echo "FAIL: create body"; jq . "$BODY_FILE" | head -20; exit 1; }
