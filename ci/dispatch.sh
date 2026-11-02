#!/bin/bash
# Start one of the repo's scheduled workflows with workflow_dispatch.
#
# GitHub's own `on: schedule` runs this repo's crons 3 to 7 hours late and
# fires an hourly cron about one slot in four. A dispatch starts in seconds,
# so the controller box keeps the clock: one systemd timer per schedule in
# controller-box/, each running `dispatch.sh <name>`.
#
# Environment:
#   GITHUB_TOKEN   fine-grained PAT: Actions read and write
#   REPO           owner/name
set -euo pipefail

REPO=${REPO:?owner/name}
: "${GITHUB_TOKEN:?}"
REF=${REF:-master}

case "${1:-}" in
  sync-hourly)     workflow=sync-upstream.yml  inputs='{"cadence":"hourly"}' ;;
  sync-six-hourly) workflow=sync-upstream.yml  inputs='{"cadence":"six-hourly"}' ;;
  sync-rebuilds)   workflow=sync-rebuilds.yml  inputs='{}' ;;
  builder-images)  workflow=builder-images.yml inputs='{}' ;;
  *) echo "usage: $0 sync-hourly|sync-six-hourly|sync-rebuilds|builder-images" >&2; exit 2 ;;
esac

echo "dispatching $workflow on $REF with $inputs"
jq -nc --arg ref "$REF" --argjson inputs "$inputs" '{ref: $ref, inputs: $inputs}' |
  curl -sS --fail-with-body -X POST -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" --data @- \
    "https://api.github.com/repos/$REPO/actions/workflows/$workflow/dispatches"
