#!/bin/bash
# Cursor publishes Grok Bot from its own Debian repository, one index per
# architecture. Each index carries the version and the SHA256, so an update
# is two small HTTP requests instead of downloading the debs, and the pool
# URL is keyed by version. bin/sync-upstream can rewrite pkgver and the
# checksums; it cannot rewrite the commit id embedded in the old
# downloads.cursor.com/grokbot/stable/<commit>/ URL.
set -euo pipefail

BASE_URL="https://downloads.cursor.com/aptrepo/dists/grok-bot/main"
declare -A DEB_ARCHES=([x86_64]=amd64 [aarch64]=arm64)

# Print "<version> <sha256>" for the newest grok-bot stanza. Newest is
# vercmp's opinion, which is the one bin/sync-upstream and pacman both use.
newest_release() {
  local index="$1"
  local version sha256 best_version="" best_sha256=""

  while read -r version sha256; do
    [[ -n "$version" && -n "$sha256" ]] || continue
    if [[ -z "$best_version" ]] || [[ "$(vercmp "$version" "$best_version")" -gt 0 ]]; then
      best_version="$version"
      best_sha256="$sha256"
    fi
  done < <(awk '
    { sub(/\r$/, "") }
    /^Package:/ { package = $2 }
    /^Version:/ { version = $2 }
    /^SHA256:/  { sha256 = $2 }
    /^$/ {
      if (package == "grok-bot" && version && sha256) print version, sha256
      package = version = sha256 = ""
    }
    END {
      if (package == "grok-bot" && version && sha256) print version, sha256
    }
  ' <<<"$index")

  [[ -n "$best_version" ]] || return 1
  echo "$best_version $best_sha256"
}

versions=()
declare -A checksums=()

for arch in "${!DEB_ARCHES[@]}"; do
  index=$(curl -fsSL "$BASE_URL/binary-${DEB_ARCHES[$arch]}/Packages")

  read -r version sha256 <<<"$(newest_release "$index")"
  if [[ -z "${version:-}" || -z "${sha256:-}" ]]; then
    echo "No usable grok-bot release found for $arch in the upstream package index" >&2
    exit 1
  fi

  versions+=("$version")
  checksums[$arch]="$sha256"
done

# A release lands one architecture at a time, and a single pkgver has to cover
# both. Report no update until they agree; the next run picks it up.
for version in "${versions[@]}"; do
  if [[ "$version" != "${versions[0]}" ]]; then
    echo "Upstream architectures are mid-release (${versions[*]}); skipping" >&2
    echo '{}'
    exit 0
  fi
done

jq -n \
  --arg pkgver "${versions[0]}" \
  --arg x86_64 "${checksums[x86_64]}" \
  --arg aarch64 "${checksums[aarch64]}" \
  '{pkgver: $pkgver, sha256sums: {x86_64: [$x86_64], aarch64: [$aarch64]}}'
