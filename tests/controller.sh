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
    sizes\?*) echo '{"sizes":[{"slug":"g5-32vcpu-64gb-50gb","available":true,"regions":["ric1"]}]}' ;;
    droplets\?*) printf '%s\n' "$DROPLETS" | jq -Rs '{droplets: [split("\n")[] | select(length>0) | split(" ") | {id: .[0]|tonumber, status: .[1], created_at: .[2]}]}' ;;
    droplets) echo '{"droplet":{"id":999}}' ;;
    droplets/*) echo '{}' ;;
  esac
}
gh_api() {
  local path=$1; shift
  echo "gh $path $*" >>"$CALLS_FILE"
  case "$path" in
    */actions/runs\?status=in_progress*) echo '{"workflow_runs":[]}' ;;
    */actions/runs\?*) jq -nc --argjson n "$QUEUED" '{workflow_runs: [range($n) | {id: .}]}' ;;
    */actions/runs/*/jobs\?*) echo '{"jobs":[{"id":'"$(echo "$path" | cut -d/ -f6)"',"status":"queued","labels":["self-hosted","omarchy-builder"]}]}' ;;
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

# A large in-progress matrix has no waiting jobs on page one. The queued
# workflow is on page two of the run listing; the same run can appear in
# both status queries while GitHub updates it, so count its jobs once.
gh_api() {
  case "$1" in
    *runs?status=queued*page=1) jq -nc '{workflow_runs: [range(100) | {id: .}]}' ;;
    *runs?status=queued*page=2) echo '{"workflow_runs":[{"id":999}]}' ;;
    *runs?status=in_progress*) echo '{"workflow_runs":[{"id":999},{"id":1000}]}' ;;
    *runs/999/jobs*page=1) jq -nc '{jobs: [range(100) | {id: .,status:"completed",labels:["omarchy-builder"]}]}' ;;
    *runs/999/jobs*page=2) echo '{"jobs":[{"id":9991,"status":"queued","labels":["omarchy-builder"]}]}' ;;
    *runs/1000/jobs*) echo '{"jobs":[{"id":10001,"status":"queued","labels":["omarchy-builder"]},{"id":10002,"status":"queued","labels":["ubuntu-latest"]},{"id":10003,"status":"in_progress","labels":["omarchy-builder"]}]}' ;;
    *jobs*) echo '{"jobs":[]}' ;;
    *) echo "Unexpected API request: $1" >&2; return 1 ;;
  esac
}
[[ $(queued_jobs) == 2 ]] || { echo "FAIL: full queue across pages and workflow states"; exit 1; }
echo "PASS: later run/job pages and in-progress workflows count each waiting builder once"

gh_api() {
  case "$1" in
    *runs?status=queued*) echo '{"workflow_runs":[{"id":1}]}' ;;
    *runs?status=in_progress*) echo '{"workflow_runs":[]}' ;;
    *jobs*page=1) jq -nc '{jobs:[range(100)|{id:.,status:"completed",labels:[]}]}' ;;
    *) return 1 ;;
  esac
}
if queued_jobs >/dev/null; then echo "FAIL: a failed later page looks like an empty queue"; exit 1; fi
echo "PASS: API failures stop the queue query"

# The create body must carry the tag (reaper scope) and substituted user-data.
BODY_FILE=$(mktemp); trap 'rm -f "$CALLS_FILE" "$BODY_FILE"' EXIT
do_api() {
  case "$1" in
    droplets) printf '%s' "${*: -1}" >"$BODY_FILE"; echo '{"droplet":{"id":1}}' ;;
    sizes*) echo '{"sizes":[{"slug":"g5-32vcpu-64gb-50gb","available":true,"regions":["ric1"]}]}' ;;
    *) echo '{"droplets":[]}' ;;
  esac
}
gh_api() { echo '{"token":"TOK"}'; }
CANDIDATES=""; create_droplet >/dev/null
jq -e '.tags == ["omarchy-builder"] and .size == "g5-32vcpu-64gb-50gb" and (.user_data | test("--token \"TOK\"")) and (.user_data | test("__") | not)' "$BODY_FILE" >/dev/null \
  && echo "PASS: create body carries tag, size, substituted user-data" \
  || { echo "FAIL: create body"; jq . "$BODY_FILE" | head -20; exit 1; }

# Sizes are tried in SIZES order, each in the regions DigitalOcean lists it
# in stock (REGIONS first); a 422 falls through to the next pair with the
# refusal's message logged, and a refused pair is not retried in the tick.
# When every pair is refused, the create fails.
do_api() {
  case "$1" in
    sizes*) echo '{"sizes":[
      {"slug":"small","available":true,"regions":["r1","r2"]},
      {"slug":"gone","available":false,"regions":["r1"]},
      {"slug":"big","available":true,"regions":["r3"]}]}' ;;
    droplets)
      local pair; pair=$(jq -r '"\(.size)@\(.region)"' <<< "${*: -1}"); echo "$pair" >>"$CALLS_FILE"
      [[ $pair == big@r3 ]] && { echo '{"droplet":{"id":2}}'; return 0; }
      echo '{"id":"unprocessable_entity","message":"Size is not available in this region."}'; return 22 ;;
  esac
}
: >"$CALLS_FILE"; CANDIDATES=""
out=$(SIZES="small gone big" REGIONS="r2"; create_droplet; create_droplet)
[[ $(paste -sd' ' "$CALLS_FILE") == "small@r2 small@r1 big@r3 big@r3" \
   && $out == *"small in r2 refused: Size is not available in this region."* && $out == *"created droplet 2"* ]] \
  && echo "PASS: a refused size falls back to the next region, then the next size, logging why" \
  || { echo "FAIL: size and region fallback"; echo "$out"; cat "$CALLS_FILE"; exit 1; }
CANDIDATES=""
if out=$(SIZES="small gone" create_droplet); then echo "FAIL: every pair refused looks like a create"; exit 1; fi
[[ $out == *"no size in 'small gone' can be created in any region"* ]] \
  && echo "PASS: every size refused everywhere fails the create" \
  || { echo "FAIL: all-refused message"; echo "$out"; exit 1; }
