#!/bin/bash
# Notion ships its desktop app as a Flatpak from its own OSTree repository.
# Each architecture's ref names the current commit, and an OSTree commit id is
# the SHA-256 of its commit object, so the commit ids are the PKGBUILD's
# checksums. The version appears only in the commit body, which names the
# Flatpak bundle it was exported from ("Notion-7.41.1.flatpak"), so an update
# costs two small requests per architecture instead of a 150 MB pull.
set -euo pipefail

REMOTE="https://app.linux-packages.notion.com"
APP_ID="com.notion.app.desktop.notion"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

versions=()
declare -A commits=()

for arch in x86_64 aarch64; do
  commit=$(curl -fsSL "$REMOTE/refs/heads/app/$APP_ID/$arch/stable" | tr -d '[:space:]')
  if [[ ! "$commit" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Unexpected $arch ref in the upstream repository: $commit" >&2
    exit 1
  fi

  curl -fsSL -o "$tmp/$arch.commit" "$REMOTE/objects/${commit:0:2}/${commit:2}.commit"
  if [[ "$(sha256sum "$tmp/$arch.commit" | cut -d' ' -f1)" != "$commit" ]]; then
    echo "The $arch commit object does not hash to its id $commit" >&2
    exit 1
  fi

  # The bundle name is the only version upstream records; a new layout has to
  # stop the sync rather than guess.
  version=$(grep -aoE "/Notion-(arm64-)?[0-9]+(\.[0-9]+)+\.flatpak" "$tmp/$arch.commit" |
    sed -E 's|^/Notion-(arm64-)?||; s|\.flatpak$||' | sort -u)
  if [[ -z "$version" || "$version" == *$'\n'* ]]; then
    echo "Could not read one version from the $arch commit body" >&2
    exit 1
  fi

  versions+=("$version")
  commits[$arch]="$commit"
done

# A release lands one architecture at a time, and a single pkgver has to cover
# both. Report no update until they agree; the next run picks it up.
if [[ "${versions[0]}" != "${versions[1]}" ]]; then
  echo "Upstream architectures are mid-release (${versions[*]}); skipping" >&2
  echo '{}'
  exit 0
fi

jq -n \
  --arg pkgver "${versions[0]}" \
  --arg x86_64 "${commits[x86_64]}" \
  --arg aarch64 "${commits[aarch64]}" \
  '{pkgver: $pkgver, sha256sums: {x86_64: [$x86_64], aarch64: [$aarch64]}}'
