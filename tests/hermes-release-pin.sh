#!/bin/bash

# hermes-desktop seeds its app into the runtime hermes-agent installs, and the
# app only runs against the commit it was built from. Both PKGBUILDs pin that
# commit by hand, so this is what stops them drifting apart.

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

pkgbuild_var() {
  (cd "$root/pkgbuilds/$1" && bash -c 'source PKGBUILD >/dev/null 2>&1; printf "%s\n" "${!1:-}"' _ "$2")
}

for var in pkgver _commit; do
  agent=$(pkgbuild_var hermes-agent "$var")
  desktop=$(pkgbuild_var hermes-desktop "$var")
  if [[ -z $agent || $agent != "$desktop" ]]; then
    echo "hermes-agent and hermes-desktop disagree on $var: '$agent' vs '$desktop'" >&2
    exit 1
  fi
done

echo "ok - hermes-agent and hermes-desktop pin the same release"
