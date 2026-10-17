#!/bin/bash
# VibeCAD publishes a checksum file beside each AppImage. Read the small
# checksum asset instead of downloading the AppImage merely to
# discover whether a package update is available.
set -euo pipefail

REPO='10-X-eng/vibecad'
RELEASES_URL="https://api.github.com/repos/${REPO}/releases?per_page=100"

current=$(awk -F= '/^pkgver=/ { print $2; exit }' PKGBUILD)
package=$(awk -F= '/^pkgname=/ { print $2; exit }' PKGBUILD)
case "$package" in
  vibecad-bin) preview=false ;;
  vibecad-preview-bin) preview=true ;;
  *) echo "Unsupported VibeCAD package: $package" >&2; exit 1 ;;
esac
releases=$(curl -fsSL "$RELEASES_URL")
jq -e 'type == "array"' <<<"$releases" >/dev/null
now=$(date +%s)
min_age=${MIN_RELEASE_AGE_SECONDS:-0}
best_version=''
best_tag=''
best_asset_url=''
best_checksum_url=''
best_published_at=''

while IFS=$'\t' read -r tag published_at assets; do
  [[ $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-(alpha|beta|RC)([0-9]+))?-build([0-9]+)$ ]] || continue

  upstream_version="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  build="${BASH_REMATCH[5]}"
  suffix="${BASH_REMATCH[3]}"
  # Require both GitHub's classification and the tag to match the track.
  # RCs never enter stable, even if a release is mislabeled on GitHub.
  if [[ $preview == true ]]; then
    [[ $suffix == RC ]] || continue
  else
    [[ -z $suffix ]] || continue
  fi
  version="${upstream_version/-RC/rc}"
  version="${version/-beta/beta}"
  version="${version/-alpha/alpha}.build${build}"
  if [[ -z $published_at ]] || ! published_epoch=$(date --date="$published_at" +%s 2>/dev/null); then
    echo "Release ${tag} has an invalid publication time" >&2
    exit 1
  fi
  if (( now - published_epoch < min_age )) && [[ ${BYPASS_MIN_RELEASE_AGE:-} != 1 ]]; then
    continue
  fi
  asset="VibeCAD-${upstream_version}-build${build}-Linux-x86_64.AppImage"
  checksum="${asset}-SHA256.txt"
  asset_url=$(jq -r --arg name "$asset" '.[] | select(.name == $name) | .browser_download_url' <<<"$assets")
  checksum_url=$(jq -r --arg name "$checksum" '.[] | select(.name == $name) | .browser_download_url' <<<"$assets")

  [[ -n $asset_url && -n $checksum_url ]] || continue
  expected_url="https://github.com/${REPO}/releases/download/${tag}/${asset}"
  if [[ $asset_url != "$expected_url" || $checksum_url != "${expected_url}-SHA256.txt" ]]; then
    echo "Unexpected asset URL for ${tag}" >&2
    exit 1
  fi
  if [[ -z $best_version ]] || (( $(vercmp "$version" "$best_version") > 0 )); then
    best_version=$version
    best_tag=$tag
    best_asset_url=$asset_url
    best_checksum_url=$checksum_url
    best_published_at=$published_at
  fi
done < <(jq -r --argjson preview "$preview" '.[] | select(.draft == false and .prerelease == $preview) | [.tag_name, .published_at, (.assets | tojson)] | @tsv' <<<"$releases")

if [[ -z $best_version ]]; then
  echo "No eligible release for ${package}; package unchanged." >&2
  echo '{}'
  exit 0
fi

if (( $(vercmp "$best_version" "$current") <= 0 )); then
  echo '{}'
  exit 0
fi

checksum_text=$(curl -fsSL "$best_checksum_url")
read -r sha256 checksum_name _ <<<"$checksum_text"
expected_name="${best_asset_url##*/}"
if [[ ! $sha256 =~ ^[0-9a-f]{64}$ ]] || [[ $checksum_name != "$expected_name" ]]; then
  echo "Invalid checksum file for ${expected_name}" >&2
  exit 1
fi

license_sha256=$(curl -fsSL \
  "https://raw.githubusercontent.com/${REPO}/${best_tag}/LICENSE" | sha256sum | cut -d' ' -f1)
icon_sha256=$(curl -fsSL \
  "https://raw.githubusercontent.com/${REPO}/${best_tag}/docs/images/vibecad-mark.svg" | sha256sum | cut -d' ' -f1)

jq -n \
  --arg pkgver "$best_version" \
  --arg published_at "$best_published_at" \
  --arg launcher "$(sha256sum vibecad | cut -d' ' -f1)" \
  --arg desktop "$(sha256sum vibecad.desktop | cut -d' ' -f1)" \
  --arg policy "$(sha256sum update-policy.json | cut -d' ' -f1)" \
  --arg license "$license_sha256" \
  --arg icon "$icon_sha256" \
  --arg sha256 "$sha256" \
  '{
    pkgver: $pkgver,
    published_at: $published_at,
    sha256sums: {
      any: [$launcher, $desktop, $policy, $license, $icon],
      x86_64: [$sha256]
    }
  }'
