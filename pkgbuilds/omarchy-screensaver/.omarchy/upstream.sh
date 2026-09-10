#!/bin/bash
set -euo pipefail

latest_url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
  'https://github.com/tobi/omarchy-launch-screensaver/releases/latest')
pkgver=${latest_url##*/}
pkgver=${pkgver#v}

checksum_for() {
  local arch="$1"
  curl -fsSL \
    "https://github.com/tobi/omarchy-launch-screensaver/releases/download/v${pkgver}/omarchy-launch-screensaver-linux-${arch}.tar.gz.sha256" |
    cut -d' ' -f1
}

x86_64=$(checksum_for x86_64)
aarch64=$(checksum_for aarch64)

if [[ -z "$pkgver" || -z "$x86_64" || -z "$aarch64" ]]; then
  echo "Latest release is missing a version or Linux asset digest" >&2
  exit 1
fi

jq -n \
  --arg pkgver "$pkgver" \
  --arg x86_64 "$x86_64" \
  --arg aarch64 "$aarch64" \
  '{pkgver: $pkgver, sha256sums: {x86_64: [$x86_64], aarch64: [$aarch64]}}'
