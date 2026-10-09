#!/bin/bash
# Cursor publishes Grok Bot from its own Debian repository, one index per
# architecture. Each index carries the version and the SHA256, so an update
# is two small HTTP requests instead of downloading the debs, and the pool
# URL is keyed by version. bin/sync-upstream can rewrite pkgver and the
# checksums; it cannot rewrite a commit id embedded in the old
# downloads.cursor.com/grokbot/stable/<commit>/ URL.
set -euo pipefail

BASE_URL="https://downloads.cursor.com/aptrepo"
declare -A DEB_ARCHES=([x86_64]=amd64 [aarch64]=arm64)

# Print "<version> <sha256>" for the newest grok-bot stanza. Newest is
# vercmp's opinion, which is the one bin/sync-upstream and pacman both use;
# sort -V disagrees with it over versions like 1.0a. The winner's Filename
# must be the versioned pool path the PKGBUILD downloads from.
newest_release() {
  local index="$1" debarch="$2"
  local version sha256 filename best_version="" best_sha256="" best_filename=""

  while read -r version sha256 filename; do
    [[ -n "$version" && -n "$sha256" ]] || continue
    if [[ -z "$best_version" ]] || [[ "$(vercmp "$version" "$best_version")" -gt 0 ]]; then
      best_version="$version"
      best_sha256="$sha256"
      best_filename="$filename"
    fi
  done < <(awk '
    { sub(/\r$/, "") }
    /^Package:/ { package = $2 }
    /^Version:/ { version = $2 }
    /^SHA256:/  { sha256 = $2 }
    /^Filename:/ { filename = $2 }
    /^$/ {
      if (package == "grok-bot" && version && sha256) print version, sha256, filename
      package = version = sha256 = filename = ""
    }
    END {
      if (package == "grok-bot" && version && sha256) print version, sha256, filename
    }
  ' <<<"$index")

  [[ -n "$best_version" ]] || return 1

  local expected="pool/grok-bot/g/gr/grok-bot_${best_version}_${debarch}.deb"
  if [[ "$best_filename" != "$expected" ]]; then
    echo "Unexpected Grok Bot $best_version $debarch Filename: '${best_filename}' (expected $expected)" >&2
    return 1
  fi

  echo "$best_version $best_sha256"
}

versions=()
declare -A checksums=()

for arch in "${!DEB_ARCHES[@]}"; do
  index=$(curl -fsSL "$BASE_URL/dists/grok-bot/main/binary-${DEB_ARCHES[$arch]}/Packages")

  read -r version sha256 <<<"$(newest_release "$index" "${DEB_ARCHES[$arch]}")"
  if [[ -z "${version:-}" || -z "${sha256:-}" ]]; then
    echo "No usable Grok Bot release found for $arch" >&2
    exit 1
  fi

  versions+=("$version")
  checksums[$arch]="$sha256"
done

# A release can land one architecture at a time. Wait until both agree so one
# pkgver always describes both artifacts.
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
