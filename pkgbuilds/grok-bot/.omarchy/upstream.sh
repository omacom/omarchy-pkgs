#!/bin/bash
# Cursor's per-architecture package indexes carry the version and SHA256 for
# each Grok Bot deb, so syncing needs only two small requests. The package pool
# keeps pinned versions available after newer releases are published.
set -euo pipefail

BASE_URL="https://downloads.cursor.com/aptrepo"
declare -A DEB_ARCHES=([x86_64]=amd64 [aarch64]=arm64)

newest_release() {
  local index="$1"
  local version sha256 best_version="" best_sha256=""

  while read -r version sha256; do
    if [[ -z "$best_version" ]] || [[ "$(vercmp "$version" "$best_version")" -gt 0 ]]; then
      best_version="$version"
      best_sha256="$sha256"
    fi
  done < <(awk '
    { sub(/\r$/, "") }
    /^Version:/ { version = $2 }
    /^SHA256:/  { sha256 = $2 }
    /^$/        { if (version && sha256) print version, sha256; version = sha256 = "" }
    END         { if (version && sha256) print version, sha256 }
  ' <<<"$index")

  [[ -n "$best_version" ]] || return 1
  echo "$best_version $best_sha256"
}

versions=()
declare -A checksums=()

for arch in "${!DEB_ARCHES[@]}"; do
  index=$(curl -fsSL "$BASE_URL/dists/grok-bot/main/binary-${DEB_ARCHES[$arch]}/Packages")

  read -r version sha256 <<<"$(newest_release "$index")"
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
