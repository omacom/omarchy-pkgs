#!/bin/bash
# A script, not Arch's compiled chromium-launcher: a binary built here would
# tie the package to the glibc of the snapshot it was built on.

flags=()
conf="${XDG_CONFIG_HOME:-$HOME/.config}/chromium-flags.conf"

# Split as a shell would, quotes included, but expand nothing: as the launcher does
if [[ -f $conf ]]; then
  mapfile -d '' flags < <(grep -vE '^[[:space:]]*(#|$)' "$conf" | tr -d '\r' | xargs -r printf '%s\0')
fi

if [[ -n ${CHROMIUM_USER_FLAGS:-} ]]; then
  mapfile -d '' -O "${#flags[@]}" flags < <(xargs -r printf '%s\0' <<<"$CHROMIUM_USER_FLAGS")
fi

export CHROME_WRAPPER=/usr/bin/chromium
export CHROME_DESKTOP=chromium.desktop
export CHROME_VERSION_EXTRA="Omarchy"

exec /usr/lib/chromium/chromium "${flags[@]}" "$@"
