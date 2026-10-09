#!/bin/bash
# Launches Valve's native arm64 Steam client.
#
# Valve's own launcher (bin_steam.sh) only knows the x86 bootstrap, so this
# does its job for linuxarm64: unpack the client on first run, keep the
# ~/.steam links the client refuses to start without, and start the client
# again whenever it exits asking to be restarted after updating itself.

set -euo pipefail

bootstrap=/usr/lib/steam/bootstraplinux_linuxarm64.tar.xz
# The exit status Steam uses to ask to be started again.
restart_status=42

if [[ $(id -u) == 0 ]]; then
  echo "steam: cannot run as root" >&2
  exit 1
fi

# Like Valve's launcher, follow ~/.steam/steam when it points at a working
# install, so a library that was moved keeps working.
steamroot=$(readlink -e "$HOME/.steam/steam" || true)
if [[ -z $steamroot || ! -x $steamroot/steamrtarm64/steam ]]; then
  steamroot=${XDG_DATA_HOME:-$HOME/.local/share}/Steam
  if [[ ! -x $steamroot/steamrtarm64/steam ]]; then
    (umask 077 && mkdir -p "$steamroot" && tar -xJf "$bootstrap" -C "$steamroot")
  fi
fi

mkdir -p "$HOME/.steam"
ln -sfn "$steamroot" "$HOME/.steam/steam"
ln -sfn "$steamroot" "$HOME/.steam/root"
# The arm64 counterpart of the sdk32/sdk64 links steam.sh makes for games
# that load the Steam API from ~/.steam.
ln -sfn "$steamroot/linuxarm64" "$HOME/.steam/sdkarm64"

cd "$steamroot"
while :; do
  status=0
  "$steamroot/steamrtarm64/steam" "$@" || status=$?
  ((status == restart_status)) || exit "$status"
done
