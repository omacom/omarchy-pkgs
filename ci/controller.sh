#!/bin/bash
# Droplet-per-job controller for the omarchy-builder runner pool.
#
# Run from a systemd timer every minute on a small always-on droplet. No
# inbound endpoint: it polls GitHub for queued jobs wanting our label, creates
# one ephemeral droplet per job (up to MAX_DROPLETS), and deletes droplets
# that have powered off, exceeded MAX_AGE_MINUTES, or are still provisioning
# after MAX_BOOT_MINUTES. The reaper does not
# trust its own bookkeeping: it lists by tag and acts on what DigitalOcean
# reports.
#
# Talks to both APIs with curl. No doctl: its saved contexts silently choose
# an account; a token in the environment cannot. Needs curl and jq.
#
# Environment:
#   DIGITALOCEAN_TOKEN   DO API token for the account that pays for droplets
#   GITHUB_TOKEN         fine-grained PAT: Actions read, Administration write
#   REPO                 owner/name
set -euo pipefail

REPO=${REPO:?owner/name}
: "${DIGITALOCEAN_TOKEN:?}" "${GITHUB_TOKEN:?}"
LABEL=${LABEL:-omarchy-builder}
TAG=${TAG:-omarchy-builder}
# Sizes to try, in order, in any region DigitalOcean lists them in stock. A
# size can sell out in a region for hours; the create is then refused with
# 422 and the next region, then the next size, is tried. REGIONS only orders
# the regions tried first. SIZE and REGION, if set, are one-item lists.
SIZES=${SIZES:-${SIZE:-g5-32vcpu-64gb-50gb g5-32vcpu-128gb-50gb}}
REGIONS=${REGIONS:-${REGION:-}}
IMAGE=${IMAGE:-ubuntu-24-04-x64}
MAX_DROPLETS=${MAX_DROPLETS:-4}
MAX_AGE_MINUTES=${MAX_AGE_MINUTES:-200}
# A droplet DigitalOcean still reports as "new" this long after creation is
# stuck provisioning. Left alone it counts as a runner booting, and holds a
# queued job until MAX_AGE_MINUTES.
MAX_BOOT_MINUTES=${MAX_BOOT_MINUTES:-10}
RUNNER_VERSION=${RUNNER_VERSION:-2.337.0}
CLOUD_INIT=${CLOUD_INIT:-$(dirname "$0")/runner-cloud-init.yaml}
# Operator public keys authorized on every builder (JSON array of strings).
# The box's env file carries them; empty means no root login.
SSH_KEYS_JSON=${SSH_KEYS_JSON:-[]}
LOCK=${LOCK:-/tmp/omarchy-controller.lock}

log() { echo "$(date '+%F %T') $*"; }

# The only two places the outside world is touched. The self-test overrides
# both, so every decision below is exercised against canned responses.
do_api() { # do_api <path> [curl args...]
  local path=$1; shift
  # --fail-with-body: a refused create still prints why.
  curl -sS --fail-with-body -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
    -H "Content-Type: application/json" "https://api.digitalocean.com/v2/$path" "$@"
}
gh_api() { # gh_api <path> [curl args...]
  local path=$1; shift
  curl -fsS -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" "https://api.github.com/$path" "$@"
}

# --- reap ------------------------------------------------------------------
reap() {
  local now id status created age
  now=$(date +%s)
  while read -r id status created; do
    [[ -n "$id" ]] || continue
    age=$(( (now - $(date -d "$created" +%s)) / 60 ))
    if [[ $status == off ]] || (( age > MAX_AGE_MINUTES )) ||
       { [[ $status == new ]] && (( age > MAX_BOOT_MINUTES )); }; then
      log "deleting droplet $id (status=$status age=${age}m)"
      do_api "droplets/$id" -X DELETE
    fi
  done < <(do_api "droplets?tag_name=$TAG&per_page=200" |
    jq -r '.droplets[] | "\(.id) \(.status) \(.created_at)"')
}

# --- demand ----------------------------------------------------------------
# Emit every item, including later pages of large build matrices. Keep API
# failures fatal so a failed query cannot look like an empty queue.
gh_items() {
  local path=$1 key=$2 page=1 response count separator="?"
  [[ $path != *"?"* ]] || separator="&"
  while :; do
    response=$(gh_api "${path}${separator}per_page=100&page=$page") || return 1
    count=$(jq -er --arg key "$key" '.[$key] | arrays | length' <<< "$response") || return 1
    jq -c --arg key "$key" '.[$key][]' <<< "$response" || return 1
    (( count == 100 )) || break
    ((page += 1))
  done
}

queued_jobs() {
  local status runs run
  # A workflow can be in progress while most of its matrix is still queued.
  runs=$(
    for status in queued in_progress; do
      gh_items "repos/$REPO/actions/runs?status=$status" workflow_runs || exit 1
    done
  ) || return 1
  jq -r '.id' <<< "$runs" | sort -u |
  while read -r run; do
    gh_items "repos/$REPO/actions/runs/$run/jobs" jobs |
      jq -r --arg l "$LABEL" 'select(.status=="queued") | select(.labels | index($l)) | .id' || return 1
  done | sort -u | wc -l
}

live_droplets() {
  # Not the ones reap() just deleted: DigitalOcean can list them for a while.
  do_api "droplets?tag_name=$TAG&per_page=200" | jq --argjson boot "$MAX_BOOT_MINUTES" '
    [.droplets[] | select(.status != "off")
      | select(.status != "new" or (now - (.created_at | fromdateiso8601)) / 60 <= $boot)] | length'
}

busy_runners() {
  gh_api "repos/$REPO/actions/runners?per_page=100" \
    | jq --arg l "$LABEL" '[.runners[] | select(.busy) | select(any(.labels[]; .name == $l))] | length'
}

# --- capacity --------------------------------------------------------------
# "size region" lines to try, best first: SIZES order, then REGIONS order,
# then every other region where DigitalOcean lists the size in stock.
candidates() {
  local page=1 response count catalog=""
  while :; do
    response=$(do_api "sizes?per_page=200&page=$page") || return 1
    count=$(jq -er '.sizes | arrays | length' <<< "$response") || return 1
    catalog+=$(jq -c '.sizes[]' <<< "$response")$'\n'
    (( count == 200 )) || break
    ((page += 1))
  done
  jq -rs --arg sizes "$SIZES" --arg regions "$REGIONS" '
    ($regions | split(" ") | map(select(length > 0))) as $pref
    | INDEX(.slug) as $by
    | $sizes | split(" ") | map(select(length > 0)) | .[]
    | . as $size | $by[$size] // {} | select(.available == true)
    | .regions as $in
    | (($pref | map(select(. as $r | $in | index($r)))) + ($in - $pref))[]
    | "\($size) \(.)"' <<< "$catalog"
}

# --- create ----------------------------------------------------------------
# Built once per tick by the first create; a refused pair is dropped from it.
CANDIDATES=""
create_droplet() {
  local token userdata name size region body response
  [[ -n $CANDIDATES ]] || CANDIDATES=$(candidates) || return 1
  token=$(gh_api "repos/$REPO/actions/runners/registration-token" -X POST | jq -r .token)
  userdata=$(sed -e "s|__REPO__|$REPO|g" -e "s|__RUNNER_TOKEN__|$token|g" \
                 -e "s|__RUNNER_LABELS__|$LABEL|g" -e "s|__RUNNER_VERSION__|$RUNNER_VERSION|g" \
                 -e "s|__SSH_KEYS_JSON__|$SSH_KEYS_JSON|" "$CLOUD_INIT")
  name="$TAG-$(date +%s)-$RANDOM"
  while read -r size region; do
    [[ -n $size ]] || continue
    body=$(jq -n --arg name "$name" --arg region "$region" --arg size "$size" --arg image "$IMAGE" \
      --arg tag "$TAG" --arg ud "$userdata" \
      '{name:$name, region:$region, size:$size, image:$image, tags:[$tag], user_data:$ud, monitoring:false}')
    log "creating $name ($size in $region)"
    if response=$(do_api droplets -X POST -d "$body"); then
      jq -r '"created droplet \(.droplet.id)"' <<< "$response"
      return 0
    fi
    log "$size in $region refused: $(jq -r .message <<< "$response" 2>/dev/null || echo "$response")"
    CANDIDATES=$(grep -Fvx "$size $region" <<< "$CANDIDATES" || true)
  done <<< "$CANDIDATES"
  # Every size refused everywhere: the rest of this tick's creates would be too.
  log "no size in '$SIZES' can be created in any region"
  return 1
}

controller_tick() {
  CANDIDATES=""
  reap
  local queued live busy available need room
  queued=$(queued_jobs)
  live=$(live_droplets)
  busy=$(busy_runners)
  # A live droplet whose runner is busy is spoken for. Only droplets still
  # booting or listening can absorb a queued job.
  available=$(( live - busy )); (( available < 0 )) && available=0
  need=$(( queued - available ))
  (( need > 0 )) || return 0
  room=$(( MAX_DROPLETS - live ))
  (( need > room )) && need=$room
  if (( need <= 0 )); then
    log "at cap ($live/$MAX_DROPLETS, $busy busy) with $queued queued"
    return 0
  fi
  local i
  for (( i = 0; i < need; i++ )); do create_droplet; done
}

if [[ "${CONTROLLER_LIBRARY_ONLY:-}" != 1 ]]; then
  exec 9>"$LOCK"; flock -n 9 || exit 0
  controller_tick
fi
