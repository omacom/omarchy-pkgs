#!/bin/bash
# Omairc publishes GitHub source tags. Download the archive only when a newer
# stable release exists, check the expected root directory, then report its hash.
set -euo pipefail

REPO='fredimachado/omairc'
RELEASES_URL="https://api.github.com/repos/$REPO/releases?per_page=100"

current=$(awk -F= '/^pkgver=/ { print $2; exit }' PKGBUILD)
releases=$(curl -fsSL "$RELEASES_URL")

best_version=''
best_tag=''
best_published_at=''

while IFS=$'\t' read -r tag published_at; do
  if [[ ! $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    continue
  fi
  version=${BASH_REMATCH[1]}

  if [[ -z $best_version ]] || (( $(vercmp "$version" "$best_version") > 0 )); then
    best_version=$version
    best_tag=$tag
    best_published_at=$published_at
  fi
done < <(jq -r '.[] | select((.draft or .prerelease) | not) | [.tag_name // "", .published_at // ""] | @tsv' <<<"$releases")

if [[ -z $best_version ]]; then
  printf 'No stable releases found for %s\n' "$REPO" >&2
  exit 1
fi

if (( $(vercmp "$best_version" "$current") <= 0 )); then
  echo '{}'
  exit 0
fi

tarball=$(mktemp)
trap 'rm -f "$tarball"' EXIT
curl -fsSL -o "$tarball" "https://github.com/$REPO/archive/refs/tags/$best_tag.tar.gz"

expected_root="omairc-$best_version"
served_roots=$(tar -tzf "$tarball" | cut -d/ -f1 | sort -u)
if [[ $served_roots != "$expected_root" ]]; then
  printf 'Release %s contains root %s, expected %s\n' "$best_tag" "$served_roots" "$expected_root" >&2
  exit 1
fi

jq -n \
  --arg pkgver "$best_version" \
  --arg published_at "$best_published_at" \
  --arg source "$(sha256sum "$tarball" | cut -d' ' -f1)" \
  '{pkgver: $pkgver, published_at: $published_at, sha256sums: {any: [$source]}}'
