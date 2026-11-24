#!/bin/bash
# A script, not Arch's compiled chromium-launcher: a binary built here would
# tie the package to the glibc of the snapshot it was built on.

flags=()
conf="${XDG_CONFIG_HOME:-$HOME/.config}/chromium-flags.conf"

if [[ -f $conf ]]; then
  while IFS= read -r line; do
    [[ $line =~ ^[[:space:]]*(#|$) ]] || flags+=("$line")
  done <"$conf"
fi

export CHROME_WRAPPER=/usr/bin/chromium
export CHROME_DESKTOP=chromium.desktop
export CHROME_VERSION_EXTRA="Omarchy"

exec /usr/lib/chromium/chromium "${flags[@]}" "$@"
