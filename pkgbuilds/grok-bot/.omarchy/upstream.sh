#!/bin/bash
# Cursor ships Grok Bot from its own Debian repository. The package index
# carries both the version and the SHA256 of the deb, so an update is one
# small HTTP request instead of a ~100 MB download.
set -euo pipefail

INDEX_URL="https://downloads.cursor.com/aptrepo/dists/grok-bot/main/binary-amd64/Packages"

# Print "<version> <sha256>" for the newest grok-bot stanza. Newest is
# vercmp's opinion, which is the one bin/sync-upstream and pacman both use.
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
    /^Package:/ { pkg = $2 }
    /^Version:/ { version = $2 }
    /^SHA256:/  { sha256 = $2 }
    /^$/        { if (pkg == "grok-bot" && version && sha256) print version, sha256; pkg = version = sha256 = "" }
    END         { if (pkg == "grok-bot" && version && sha256) print version, sha256 }
  ' <<<"$index")

  [[ -n "$best_version" ]] || return 1
  echo "$best_version $best_sha256"
}

index=$(curl -fsSL "$INDEX_URL")
read -r version sha256 <<<"$(newest_release "$index")"
if [[ -z "${version:-}" || -z "${sha256:-}" ]]; then
  echo "No usable grok-bot release found in the upstream package index" >&2
  exit 1
fi

jq -n \
  --arg pkgver "$version" \
  --arg x86_64 "$sha256" \
  '{pkgver: $pkgver, sha256sums: {x86_64: [$x86_64]}}'
