#!/bin/bash
# Dispatch sync-rebuilds as soon as the edge mirror publishes a new Arch sync.
#
# mirror.omarchy.org follows Arch every hour, so edge machines get a new Qt
# (or anything else a package names in rebuild_on) within the hour, while the
# hourly sync-rebuilds could still leave a Qt private-API consumer like
# quickshell built against the old one until its next run. The mirror stamps lastsync
# when an upload finishes; a strictly newer stamp starts sync-rebuilds, which bumps
# what moved and does nothing otherwise. The hourly timer stays as the backstop,
# and for aarch64, whose versions come from Arch Linux ARM, not this mirror.
#
# Environment: GITHUB_TOKEN and REPO for dispatch.sh, STATE_DIRECTORY from systemd.
set -euo pipefail

MIRROR=${MIRROR:-https://mirror.omarchy.org}
MAX_FUTURE_SKEW=86400
state_dir=${STATE_DIRECTORY:?}
state_dir=${state_dir%/}
state=$state_dir/mirror-lastsync
lock=$state_dir/.mirror-lastsync.lock

fetch_tmp=""
state_tmp=""
cleanup() {
  if [[ -n $fetch_tmp ]]; then
    rm -f -- "$fetch_tmp"
  fi
  if [[ -n $state_tmp ]]; then
    rm -f -- "$state_tmp"
  fi
}
trap cleanup EXIT

has_nul_bytes() {
  [[ $(LC_ALL=C tr -dc '\0' <"$1" | wc -c) -ne 0 ]]
}

now=$(date +%s)
fetch_tmp=$(mktemp)
# Write to a temp file rather than stdout so a timed-out partial transfer cannot
# concatenate with a retry body. Retry + per-attempt + dispatch timeouts stay
# well inside omarchy-rebuilds-on-mirror-sync.service's TimeoutStartSec=90.
curl -fsS --connect-timeout 10 --max-time 15 --retry 2 --retry-delay 1 --retry-max-time 20 \
  -H "Cache-Control: no-cache" \
  --output "$fetch_tmp" \
  "${MIRROR%/}/lastsync?$now"
if has_nul_bytes "$fetch_tmp"; then
  echo "dispatch-on-mirror-sync: NUL bytes in lastsync response from $MIRROR" >&2
  exit 1
fi
raw_lastsync=$(<"$fetch_tmp")
rm -f -- "$fetch_tmp"
fetch_tmp=""

if [[ ! $raw_lastsync =~ ^[0-9]{1,18}$ ]]; then
  echo "dispatch-on-mirror-sync: unexpected lastsync from $MIRROR: ${raw_lastsync:0:80}" >&2
  exit 1
fi
lastsync=$((10#$raw_lastsync))
if (( lastsync == 0 || lastsync > now + MAX_FUTURE_SKEW )); then
  echo "dispatch-on-mirror-sync: out-of-range lastsync from $MIRROR: $lastsync (now=$now)" >&2
  exit 1
fi

if [[ ! -d $state_dir ]]; then
  echo "dispatch-on-mirror-sync: missing state directory $state_dir" >&2
  exit 1
fi
exec 9>"$lock"
flock -w 10 9

previous=0
if [[ -e $state || -L $state ]]; then
  if [[ -L $state || ! -f $state || ! -r $state ]]; then
    echo "dispatch-on-mirror-sync: unreadable state file $state" >&2
    exit 1
  fi
  if has_nul_bytes "$state"; then
    echo "dispatch-on-mirror-sync: NUL bytes in state file $state" >&2
    exit 1
  fi
  raw_previous=$(<"$state")
  if [[ ! $raw_previous =~ ^[0-9]{1,18}$ ]]; then
    echo "dispatch-on-mirror-sync: invalid state in $state: ${raw_previous:0:80}" >&2
    exit 1
  fi
  previous=$((10#$raw_previous))
  if (( previous > now + MAX_FUTURE_SKEW )); then
    echo "dispatch-on-mirror-sync: out-of-range state in $state: $previous (now=$now)" >&2
    exit 1
  fi
fi

if (( lastsync <= previous )); then
  if (( lastsync < previous )); then
    echo "dispatch-on-mirror-sync: ignoring older lastsync $lastsync (state is $previous)" >&2
  fi
  exit 0
fi

state_tmp=$(mktemp "$state_dir/.mirror-lastsync.tmp.XXXXXX")
printf "%s\n" "$lastsync" >"$state_tmp"

timeout -k 5 30 "$(dirname "$0")/dispatch.sh" sync-rebuilds
mv -f -- "$state_tmp" "$state"
state_tmp=""
