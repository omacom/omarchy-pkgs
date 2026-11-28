#!/bin/bash
# Dispatch sync-rebuilds as soon as the edge mirror publishes a new Arch sync.
#
# mirror.omarchy.org follows Arch every hour, so edge machines get a new Qt
# (or anything else a package names in rebuild_on) within the hour, while the
# hourly sync-rebuilds could still leave a Qt private-API consumer like
# quickshell built against the old one until its next run. The mirror stamps lastsync
# when an upload finishes; a new stamp starts sync-rebuilds, which bumps what
# moved and does nothing otherwise. The hourly timer stays as the backstop,
# and for aarch64, whose versions come from Arch Linux ARM, not this mirror.
#
# Environment: GITHUB_TOKEN and REPO for dispatch.sh, STATE_DIRECTORY from systemd.
set -euo pipefail

MIRROR=${MIRROR:-https://mirror.omarchy.org}
state=${STATE_DIRECTORY:?}/mirror-lastsync

lastsync=$(curl -fsS --max-time 30 "$MIRROR/lastsync")
if [[ ! $lastsync =~ ^[0-9]+$ ]]; then
  echo "dispatch-on-mirror-sync: unexpected lastsync from $MIRROR: $lastsync" >&2
  exit 1
fi

if [[ $lastsync != "$(cat "$state" 2>/dev/null)" ]]; then
  "$(dirname "$0")/dispatch.sh" sync-rebuilds
  echo "$lastsync" >"$state"
fi
