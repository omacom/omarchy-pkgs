#!/bin/bash
# TMOG publishes no manifest for its Linux builds -- release.json describes the
# macOS DMG only -- so the version comes from /version.txt and the checksum has
# to be computed from the artifact itself. That is 8 MB, and only when the
# version has actually moved, so the six-hourly check normally costs one tiny
# request.
#
# Since 1.0.0 upstream serves versioned tarballs under /rtm/downloads/. The hook
# still checks the tarball's top-level directory against /version.txt so a
# half-published release cannot slip through.
set -euo pipefail

BASE_URL="https://tmog.org"

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

tarball=$(mktemp)
trap 'rm -f "$tarball"' EXIT

curl -fsSL -o "$tarball" \
  "$BASE_URL/rtm/downloads/TaskManagerOG-${version}-linux-x86_64.tar.gz"

# Every entry is listed rather than just the first: `head -1` would close the
# pipe under `tar` and take the whole hook down with SIGPIPE, and reading them
# all also catches a tarball that unpacks more than one top-level directory.
expected_dir="TaskManagerOG-${version}-linux-x86_64"
served_dir=$(tar tzf "$tarball" | cut -d/ -f1 | sort -u)
if [[ $served_dir != "$expected_dir" ]]; then
  echo "Download holds $served_dir, but /version.txt announced $version; skipping" >&2
  echo '{}'
  exit 0
fi

# "any" is bin/sync-upstream's name for the unsuffixed sha256sums array, which
# is the one this package has: upstream publishes x86_64 alone, so there is a
# single plain source=() rather than per-architecture arrays.
jq -n \
  --arg pkgver "$version" \
  --arg sha256 "$(sha256sum "$tarball" | cut -d' ' -f1)" \
  '{pkgver: $pkgver, sha256sums: {any: [$sha256]}}'
