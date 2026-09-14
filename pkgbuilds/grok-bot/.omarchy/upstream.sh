#!/bin/bash
# Grok Bot ships through Cursor's update service. The linux-x64 feed answers
# with the newest stable version and a URL whose path carries the build hash
# the .deb lives under, so the check is one small request. The feed publishes
# no checksum, so a release that is actually new is downloaded once to hash --
# hence the version check before the fetch.
set -euo pipefail

FEED_URL="https://api2.cursor.sh/updates/api/update/linux-x64/sand/0.0.0/latest/stable"
DOWNLOAD_BASE="https://downloads.cursor.com/grokbot/stable"

feed=$(curl -fsSL -H 'cache-control: no-cache' "$FEED_URL")
version=$(jq -er '.version // .name' <<<"$feed")
feed_url=$(jq -er '.url' <<<"$feed")

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Upstream feed carried an unexpected version: $version" >&2
  exit 1
fi

# The feed points at the AppImage's zsync file; the .deb sits beside it under
# the same build hash. Anything else -- a moved CDN, a new path layout -- has
# to stop the sync rather than pin a checksum to a URL nobody will fetch.
if [[ ! "$feed_url" =~ ^${DOWNLOAD_BASE}/([0-9a-f]{40})/linux/x64/[^/]+$ ]]; then
  echo "Upstream feed URL does not match the expected layout: $feed_url" >&2
  exit 1
fi
commit="${BASH_REMATCH[1]}"

current=$(awk -F= '/^pkgver=/ { print $2; exit }' PKGBUILD)
if [[ -n "$current" ]] && [[ "$(vercmp "$version" "$current")" -le 0 ]]; then
  echo '{}'
  exit 0
fi

# Darwin can ship ahead of Linux under the same version; wait until the .deb
# is actually there rather than failing the run.
deb_url="$DOWNLOAD_BASE/$commit/linux/x64/grok-bot_${version}_amd64.deb"
status=$(curl -fsSIL -o /dev/null -w '%{http_code}' "$deb_url" || true)
if [[ "$status" != "200" ]]; then
  echo "Linux .deb for $version not published yet ($status): $deb_url" >&2
  echo '{}'
  exit 0
fi

deb_sum=$(curl -fsSL "$deb_url" | sha256sum | cut -d' ' -f1)
# The PKGBUILD's checksum array also covers the two local files; the whole
# array is rewritten, so their sums are reported alongside.
wrapper_sum=$(sha256sum grok-bot.sh | cut -d' ' -f1)
desktop_sum=$(sha256sum grok-bot.desktop | cut -d' ' -f1)

jq -n --arg pkgver "$version" --arg commit "$commit" \
  --arg deb "$deb_sum" --arg wrapper "$wrapper_sum" --arg desktop "$desktop_sum" \
  '{pkgver: $pkgver, vars: {_commit: $commit}, sha256sums: {any: [$deb, $wrapper, $desktop]}}'
