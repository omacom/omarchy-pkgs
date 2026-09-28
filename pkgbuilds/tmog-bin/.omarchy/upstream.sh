#!/bin/bash
# TMOG publishes no manifest for its Linux builds -- release.json describes the
# macOS DMG only -- so the version comes from /rtm/version.txt. Each Linux
# artifact is published under a versioned name with a `<artifact>.sha256`
# sidecar beside it, and that sidecar is the checksum reported here, so the
# six-hourly check costs two tiny requests and never the tarball itself.
set -euo pipefail

BASE_URL="https://tmog.org/rtm"

current=$(grep -m1 '^pkgver=' PKGBUILD | cut -d= -f2- | tr -d "\"'")

version=$(curl -fsSL "$BASE_URL/version.txt" | tr -d '[:space:]')
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Unusable version from $BASE_URL/version.txt: '$version'" >&2
  exit 1
fi

if [[ $version == "$current" ]]; then
  echo '{}'
  exit 0
fi

# The sidecar names the file it describes; insisting on that name catches a
# sidecar left over from another release or architecture. A failed download or
# a file without a trailing newline leaves `read` short, which the check below
# reports rather than letting set -e exit silently.
artifact="TaskManagerOG-${version}-linux-x86_64.tar.gz"
sha256="" name=""
read -r sha256 name < <(curl -fsSL "$BASE_URL/downloads/$artifact.sha256") || true
if [[ ! $sha256 =~ ^[0-9a-f]{64}$ || ${name#\*} != "$artifact" ]]; then
  echo "Unusable checksum for $artifact: '$sha256 $name'" >&2
  exit 1
fi

# "any" is bin/sync-upstream's name for the unsuffixed sha256sums array, which
# is the one this package has: it builds x86_64 alone, so there is a single
# plain source=() rather than per-architecture arrays.
jq -n \
  --arg pkgver "$version" \
  --arg sha256 "$sha256" \
  '{pkgver: $pkgver, sha256sums: {any: [$sha256]}}'
