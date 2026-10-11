#!/bin/bash
set -euo pipefail

repo=${FAM_OS_GITHUB_REPOSITORY:-demimagic-ML/FAM-os}
release=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest")
tag=$(jq -er '.tag_name' <<<"$release")
[[ $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || {
  echo "FAM_OS latest release tag is not a stable semantic version: $tag" >&2
  exit 1
}
version=${BASH_REMATCH[1]}
current=$(awk -F= '/^pkgver=/ { gsub(/["'\'' ]/, "", $2); print $2; exit }' PKGBUILD)
if [[ -n $current ]] && (( $(vercmp "$version" "$current") <= 0 )); then
  echo '{}'
  exit 0
fi

checksum_url=$(jq -er '.assets[] | select(.name == "SHA256SUMS") | .browser_download_url' <<<"$release")
checksums=$(curl -fsSL "$checksum_url")
asset="fam-os-${version}.tar.gz"
sha256=$(awk -v asset="$asset" \
  '{name=$2; sub(/^\*/, "", name); sub(/^\.\//, "", name)} name == asset { print $1; exit }' \
  <<<"$checksums")
[[ $sha256 =~ ^[0-9a-f]{64}$ ]] || {
  echo "SHA256SUMS contains no valid digest for $asset" >&2
  exit 1
}

jq -n --arg pkgver "$version" --arg sha256 "$sha256" \
  '{pkgver: $pkgver, sha256sums: {any: [$sha256]}}'
