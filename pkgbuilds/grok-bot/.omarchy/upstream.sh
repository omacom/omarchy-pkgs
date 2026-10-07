#!/usr/bin/env bash
# Cursor's Debian indexes provide version and SHA256 metadata for both
# architectures, so sync does not need to download the application binaries.
set -euo pipefail

BASE_URL="https://downloads.cursor.com/aptrepo/dists/grok-bot/main"
declare -A DEBIAN_ARCHES=([x86_64]=amd64 [aarch64]=arm64)
declare -A VERSIONS=() CHECKSUMS=()

newest_release() {
  local package_index="$1" package_arch="$2"
  local best_version="" best_checksum="" best_filename=""
  local version checksum filename

  while IFS=$'\t' read -r version checksum filename; do
    [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._+]*$ ]] || continue
    [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || continue

    if [[ -z "$best_version" ]] || [[ "$(vercmp "$version" "$best_version")" -gt 0 ]]; then
      best_version="$version"
      best_checksum="$checksum"
      best_filename="$filename"
    fi
  done < <(awk -v target="grok-bot" '
    BEGIN { RS = ""; FS = "\n" }
    {
      package = version = checksum = filename = ""
      for (i = 1; i <= NF; i++) {
        sub(/\r$/, "", $i)
        if ($i ~ /^Package: /) package = substr($i, 10)
        if ($i ~ /^Version: /) version = substr($i, 10)
        if ($i ~ /^SHA256: /) checksum = substr($i, 9)
        if ($i ~ /^Filename: /) filename = substr($i, 11)
      }
      if (package == target && version != "" && checksum != "" && filename != "") {
        print version "\t" checksum "\t" filename
      }
    }
  ' <<<"$package_index")

  [[ -n "$best_version" ]] || return 1

  local expected_filename="pool/grok-bot/g/gr/grok-bot_${best_version}_${package_arch}.deb"
  [[ "$best_filename" == "$expected_filename" ]] || {
    echo "Unexpected Grok Bot package path for ${package_arch}: ${best_filename}" >&2
    return 1
  }

  printf '%s\t%s\n' "$best_version" "$best_checksum"
}

for arch in x86_64 aarch64; do
  index_url="${BASE_URL}/binary-${DEBIAN_ARCHES[$arch]}/Packages"
  package_index="$(curl -fsSL --retry 3 "$index_url")"
  package_index="${package_index//$'\r'/}"

  if ! release="$(newest_release "$package_index" "${DEBIAN_ARCHES[$arch]}")"; then
    echo "No usable Grok Bot release found for ${arch} in ${index_url}" >&2
    exit 1
  fi

  IFS=$'\t' read -r version checksum <<<"$release"
  VERSIONS[$arch]="$version"
  CHECKSUMS[$arch]="$checksum"
done

if [[ "${VERSIONS[x86_64]}" != "${VERSIONS[aarch64]}" ]]; then
  echo "Grok Bot architectures are mid-release (${VERSIONS[x86_64]} vs ${VERSIONS[aarch64]}); skipping" >&2
  echo '{}'
  exit 0
fi

jq -cn \
  --arg pkgver "${VERSIONS[x86_64]}" \
  --arg x86_64 "${CHECKSUMS[x86_64]}" \
  --arg aarch64 "${CHECKSUMS[aarch64]}" \
  '{pkgver: $pkgver, sha256sums: {x86_64: [$x86_64], aarch64: [$aarch64]}}'
