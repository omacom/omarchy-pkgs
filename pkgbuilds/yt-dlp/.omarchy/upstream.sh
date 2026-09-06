#!/bin/bash
# yt-dlp ships a signed SHA2-256SUMS beside every release, so an update costs two
# small requests instead of a 5.7 MB download. The version comes from the
# /releases/latest redirect rather than the API, which is rate limited per IP and
# would fail the sync on a busy build host.
set -euo pipefail

REPO_URL="https://github.com/yt-dlp/yt-dlp"
TARBALL="yt-dlp.tar.gz"

# The redirect target ends in /releases/tag/<version>; anything else means GitHub
# answered with something other than a release and the version cannot be trusted.
location=$(curl -fsS -o /dev/null -w '%{url_effective}' -L "$REPO_URL/releases/latest")
pkgver="${location##*/releases/tag/}"

if [[ "$pkgver" == "$location" || -z "$pkgver" ]]; then
  echo "Could not read a release tag from $location" >&2
  exit 1
fi

sha256=$(curl -fsSL "$REPO_URL/releases/download/$pkgver/SHA2-256SUMS" |
  awk -v file="$TARBALL" '$2 == file { print $1; exit }')

if [[ -z "$sha256" ]]; then
  echo "Release $pkgver publishes no checksum for $TARBALL" >&2
  exit 1
fi

jq -n --arg pkgver "$pkgver" --arg sha256 "$sha256" \
  '{pkgver: $pkgver, sha256sums: {any: [$sha256]}}'
