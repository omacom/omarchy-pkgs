#!/bin/bash
# Droplet-per-job controller for the omarchy-builder runner pool.
#
# Run from a systemd timer every minute on a small always-on droplet. No
# inbound endpoint: it polls GitHub for queued jobs wanting our label, creates
# one ephemeral droplet per job (up to MAX_DROPLETS), and deletes droplets
# that have powered off or exceeded MAX_AGE_MINUTES. The reaper does not
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
REGION=${REGION:-ric1}
SIZE=${SIZE:-g5-32vcpu-64gb-50gb}
IMAGE=${IMAGE:-ubuntu-24-04-x64}
MAX_DROPLETS=${MAX_DROPLETS:-4}
MAX_AGE_MINUTES=${MAX_AGE_MINUTES:-200}
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
  curl -fsS -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
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
    if [[ $status == off ]] || (( age > MAX_AGE_MINUTES )); then
      log "deleting droplet $id (status=$status age=${age}m)"
      do_api "droplets/$id" -X DELETE
    fi
  done < <(do_api "droplets?tag_name=$TAG&per_page=200" |
    jq -r '.droplets[] | "\(.id) \(.status) \(.created_at)"')
}

# --- demand ----------------------------------------------------------------
queued_jobs() {
  local run
  gh_api "repos/$REPO/actions/runs?status=queued&per_page=50" --get \
    | jq -r '.workflow_runs[].id' |
  while read -r run; do
    gh_api "repos/$REPO/actions/runs/$run/jobs" \
      | jq -r --arg l "$LABEL" '.jobs[] | select(.status=="queued") | select(.labels | index($l)) | .id'
  done | wc -l
}

live_droplets() {
  do_api "droplets?tag_name=$TAG&per_page=200" | jq '[.droplets[] | select(.status != "off")] | length'
}

busy_runners() {
  gh_api "repos/$REPO/actions/runners?per_page=100" \
    | jq --arg l "$LABEL" '[.runners[] | select(.busy) | select(any(.labels[]; .name == $l))] | length'
}

# --- create ----------------------------------------------------------------
create_droplet() {
  local token userdata name body
  token=$(gh_api "repos/$REPO/actions/runners/registration-token" -X POST | jq -r .token)
  userdata=$(sed -e "s|__REPO__|$REPO|g" -e "s|__RUNNER_TOKEN__|$token|g" \
                 -e "s|__RUNNER_LABELS__|$LABEL|g" -e "s|__RUNNER_VERSION__|$RUNNER_VERSION|g" \
                 -e "s|__SSH_KEYS_JSON__|$SSH_KEYS_JSON|" "$CLOUD_INIT")
  name="$TAG-$(date +%s)-$RANDOM"
  body=$(jq -n --arg name "$name" --arg region "$REGION" --arg size "$SIZE" --arg image "$IMAGE" \
    --arg tag "$TAG" --arg ud "$userdata" \
    '{name:$name, region:$region, size:$size, image:$image, tags:[$tag], user_data:$ud, monitoring:false}')
  log "creating $name ($SIZE)"
  do_api droplets -X POST -d "$body" | jq -r '"created droplet \(.droplet.id)"'
}

controller_tick() {
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
