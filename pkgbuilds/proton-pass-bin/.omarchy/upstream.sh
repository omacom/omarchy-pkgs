#!/bin/bash
# Proton publishes Linux releases in its own JSON feed, the one the desktop app
# checks for updates. Only Stable entries count: the feed also lists Beta
# builds, which are often newer. RolloutPercentage is ignored on purpose,
# because Proton's download page serves the newest Stable to every new install.
#
# The feed carries SHA-512 checksums only, and bin/sync-upstream records
# SHA-256. So when a newer release exists, the hook downloads the deb (about
# 100 MB), checks it against Proton's SHA-512 and hashes it. Otherwise the
# six-hourly check costs one small request.
set -euo pipefail

FEED_URL="https://proton.me/download/PassDesktop/linux/x64/version.json"

current=$(grep -m1 '^pkgver=' PKGBUILD | cut -d= -f2- | tr -d "\"'")
feed=$(curl -fsSL "$FEED_URL")

# Newest is vercmp's opinion, which is the one bin/sync-upstream and pacman
# both use. Feed order is not trusted.
best_version="" best_url="" best_sha512=""
while IFS=$'\t' read -r version url sha512; do
  if [[ ! $version =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "Unusable Stable version in $FEED_URL: '${version}'" >&2
    exit 1
  fi
  if [[ -z $best_version ]] || (($(vercmp "$version" "$best_version") > 0)); then
    best_version=$version
    best_url=$url
    best_sha512=$sha512
  fi
done < <(jq -r '
  .Releases[]
  | select(.CategoryName == "Stable")
  | [.Version, (.File[] | select(.Identifier | startswith(".deb")) | .Url, .Sha512CheckSum)]
  | @tsv
' <<<"$feed")

if [[ -z $best_version ]]; then
  echo "No Stable release found in $FEED_URL" >&2
  exit 1
fi

if (($(vercmp "$best_version" "$current") <= 0)); then
  echo '{}'
  exit 0
fi

# The PKGBUILD rebuilds the download URL from pkgver, so a release served from
# anywhere else has to stop the sync rather than pin a checksum to a URL
# nobody will fetch.
expected_url="https://proton.me/download/pass/linux/proton-pass_${best_version}_amd64.deb"
if [[ $best_url != "$expected_url" ]]; then
  echo "Unexpected deb URL for $best_version: '$best_url'" >&2
  exit 1
fi
if [[ ! $best_sha512 =~ ^[0-9a-f]{128}$ ]]; then
  echo "Unusable SHA-512 for $best_version: '$best_sha512'" >&2
  exit 1
fi

deb=$(mktemp)
trap 'rm -f "$deb"' EXIT
curl -fsSL -o "$deb" "$best_url"

if ! sha512sum --check --status - <<<"$best_sha512  $deb"; then
  echo "Downloaded $best_url does not match the feed's SHA-512" >&2
  exit 1
fi

# "any" is bin/sync-upstream's name for the unsuffixed sha256sums array, the
# one this x86_64-only package uses.
jq -n \
  --arg pkgver "$best_version" \
  --arg sha256 "$(sha256sum "$deb" | cut -d' ' -f1)" \
  '{pkgver: $pkgver, sha256sums: {any: [$sha256]}}'
