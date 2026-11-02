#!/bin/bash
# The Linux x86_64 manifest supplies the version: the shared version.txt can
# advance before Linux ships. Its checksum describes the AppImage, so keep
# using the tarball's own <artifact>.sha256 sidecar for the package checksum.
# The six-hourly check costs at most two tiny requests, never the tarball.
set -euo pipefail

BASE_URL="https://tmog.org/rtm"

current=$(grep -m1 '^pkgver=' PKGBUILD | cut -d= -f2- | tr -d "\"'")

manifest_url="$BASE_URL/downloads/release-linux.json"
manifest=$(curl -fsSL "$manifest_url")
if ! version=$(jq -er '
  select(.schemaVersion == 1 and .platform == "Linux" and .architecture == "x86_64")
  | .version | select(type == "string" and test("\\A[0-9]+\\.[0-9]+\\.[0-9]+\\z"))
' <<<"$manifest"); then
  echo "Unusable Linux x86_64 release manifest from $manifest_url" >&2
  exit 1
fi

if [[ $version == "$current" ]]; then
  echo '{}'
  exit 0
fi

# The sidecar names the file it describes; insisting on that name catches a
# sidecar left over from another release or architecture. Fetch separately so
# a failed curl cannot be hidden by process substitution or a partial response.
artifact="TaskManagerOG-${version}-linux-x86_64.tar.gz"
checksum=$(curl -fsSL "$BASE_URL/downloads/$artifact.sha256")
sha256="" name=""
read -r sha256 name <<<"$checksum"
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
