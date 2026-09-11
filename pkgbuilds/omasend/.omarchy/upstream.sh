#!/bin/bash
# Omasend publishes architecture-specific Linux archives and a checksum
# manifest with each stable GitHub release. Verify both archives before
# reporting an update to the Omarchy package synchronizer.
set -euo pipefail

REPO='huacnlee/omasend'
RELEASES_URL="https://api.github.com/repos/$REPO/releases?per_page=100"

current=$(awk -F= '/^pkgver=/ { print $2; exit }' PKGBUILD)
releases=$(curl -fsSL "$RELEASES_URL")
now=$(date +%s)
min_age=${MIN_RELEASE_AGE_SECONDS:-0}

candidates=0
best_version=''
best_tag=''
best_published_at=''

while IFS=$'\t' read -r tag published_at; do
  if [[ ! $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    printf '%s has an unusable stable release tag: %s\n' "$REPO" "${tag:-<empty>}" >&2
    exit 1
  fi
  version=${BASH_REMATCH[1]}

  if [[ -z $published_at ]] || ! published_epoch=$(date --date="$published_at" +%s 2>/dev/null); then
    printf '%s release %s has an invalid publication time\n' "$REPO" "$tag" >&2
    exit 1
  fi
  candidates=$((candidates + 1))

  if ((now - published_epoch < min_age)) && [[ ${BYPASS_MIN_RELEASE_AGE:-} != 1 ]]; then
    continue
  fi

  if [[ -z $best_version ]] || (( $(vercmp "$version" "$best_version") > 0 )); then
    best_version=$version
    best_tag=$tag
    best_published_at=$published_at
  fi
done < <(jq -r '.[] | select((.draft or .prerelease) | not) | [.tag_name // "", .published_at // ""] | @tsv' <<<"$releases")

if ((candidates == 0)); then
  printf 'No stable releases found for %s\n' "$REPO" >&2
  exit 1
fi

if [[ -z $best_version ]] || (( $(vercmp "$best_version" "$current") <= 0 )); then
  echo '{}'
  exit 0
fi

release_url="https://github.com/$REPO/releases/download/$best_tag"
checksums=$(curl -fsSL "$release_url/SHA256SUMS")

checksum_for() {
  local asset=$1
  local checksum
  checksum=$(awk -v asset="$asset" '$2 == asset || $2 == "*" asset { print $1 }' <<<"$checksums")
  if [[ ! $checksum =~ ^[0-9a-f]{64}$ ]]; then
    printf 'Release %s has no unique SHA-256 checksum for %s\n' "$best_tag" "$asset" >&2
    return 1
  fi
  printf '%s\n' "$checksum"
}

x86_asset="omasend-$best_version-x86_64-unknown-linux-gnu.tar.gz"
arm_asset="omasend-$best_version-aarch64-unknown-linux-gnu.tar.gz"
x86_sum=$(checksum_for "$x86_asset")
arm_sum=$(checksum_for "$arm_asset")

for item in "$x86_asset:$x86_sum" "$arm_asset:$arm_sum"; do
  asset=${item%%:*}
  expected=${item#*:}
  archive=$(mktemp)
  curl -fsSL -o "$archive" "$release_url/$asset"
  actual=$(sha256sum "$archive" | cut -d' ' -f1)
  if [[ $actual != "$expected" ]]; then
    printf 'Release %s archive %s does not match SHA256SUMS\n' "$best_tag" "$asset" >&2
    exit 1
  fi
  archive_entries=$(tar -tzf "$archive")
  if ! grep -Fxq 'omasend' <<<"$archive_entries"; then
    printf 'Release %s archive %s does not contain omasend\n' "$best_tag" "$asset" >&2
    exit 1
  fi
  rm -f "$archive"
done

jq -n \
  --arg pkgver "$best_version" \
  --arg published_at "$best_published_at" \
  --arg x86 "$x86_sum" \
  --arg arm "$arm_sum" \
  '{pkgver: $pkgver, published_at: $published_at, sha256sums: {x86_64: [$x86], aarch64: [$arm]}}'
