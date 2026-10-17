#!/bin/bash
# T3 Code publishes electron-builder's update feed beside every release, so the
# newest version costs one small request. Each feed's checksum is a base64
# SHA-512 and makepkg wants hex SHA-256, so a release that is actually new still
# has to be downloaded once per architecture to hash -- hence the version check
# before the fetch.
set -euo pipefail

FEED_URL="https://github.com/pingdotgg/t3code/releases/latest/download/latest-linux.yml"
RELEASE_URL="https://github.com/pingdotgg/t3code/releases/download"

feed=$(curl -fsSL "$FEED_URL")
version=$(awk '/^version:/ { print $2; exit }' <<<"$feed" | tr -d '"'\''')
asset=$(awk '/^path:/ { print $2; exit }' <<<"$feed" | tr -d '"'\''')

if [[ -z "$version" || -z "$asset" ]]; then
  echo "Upstream feed carried no version or asset name" >&2
  exit 1
fi

current=$(awk -F= '/^pkgver=/ { print $2; exit }' PKGBUILD)
if [[ -n "$current" ]] && [[ "$(vercmp "$version" "$current")" -le 0 ]]; then
  echo '{}'
  exit 0
fi

# The PKGBUILD builds fixed asset names, so a feed naming anything else --
# a rename, or an arm64 build reaching the Linux feed first -- has to stop the
# sync rather than pin that file's checksum to a URL nobody will fetch.
expected="T3-Code-${version}-x86_64.AppImage"
if [[ "$asset" != "$expected" ]]; then
  echo "Upstream feed names $asset, but the PKGBUILD builds $expected" >&2
  exit 1
fi

# Pin the ARM feed to the same release, so a partially published release or a
# latest-release change cannot mix versions between architectures.
arm_feed=$(curl -fsSL "$RELEASE_URL/v${version}/latest-linux-arm64.yml")
arm_version=$(awk '/^version:/ { print $2; exit }' <<<"$arm_feed" | tr -d '"'\''')
arm_asset=$(awk '/^path:/ { print $2; exit }' <<<"$arm_feed" | tr -d '"'\''')
if [[ "$arm_version" != "$version" || "$arm_asset" != "T3-Code-${version}-arm64.AppImage" ]]; then
  echo "Upstream ARM feed does not match T3-Code-${version}-arm64.AppImage" >&2
  exit 1
fi

sha256=$(curl -fsSL "$RELEASE_URL/v${version}/${asset}" | sha256sum | cut -d' ' -f1)
arm_sha256=$(curl -fsSL "$RELEASE_URL/v${version}/${arm_asset}" | sha256sum | cut -d' ' -f1)

jq -n --arg pkgver "$version" --arg sha256 "$sha256" --arg arm_sha256 "$arm_sha256" \
  '{pkgver: $pkgver, sha256sums: {x86_64: [$sha256], aarch64: [$arm_sha256]}}'
