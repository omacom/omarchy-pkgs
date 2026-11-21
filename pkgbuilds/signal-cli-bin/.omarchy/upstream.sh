#!/bin/bash
# signal-cli publishes GitHub releases with a detached GPG signature per asset
# and no checksum manifest, so the declarative github provider does not fit:
# the checksum has to be computed from the tarball itself. That download is
# 110 MB and only happens once a release is newer than the checked-in one.
# The tarball is verified against the key in keys/pgp before it is reported,
# so a release asset that AsamK did not sign never reaches a sync PR.
set -euo pipefail

REPO="AsamK/signal-cli"
MIN_AGE=${MIN_RELEASE_AGE_SECONDS:-0}

current=$(grep -m1 '^pkgver=' PKGBUILD | cut -d= -f2- | tr -d "\"'")

releases=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=30")

# Newest stable release that has cleared the quarantine window.
best_ver="" best_tag="" best_at=""
now=$(date +%s)
while IFS=$'\t' read -r tag published_at; do
  [[ $tag =~ ^v([0-9]+(\.[0-9]+)+)$ ]] || { echo "Unusable tag in $REPO feed: '$tag'" >&2; exit 1; }
  ver=${BASH_REMATCH[1]}
  epoch=$(date --date="$published_at" +%s)
  if (( now - epoch < MIN_AGE )) && [[ ${BYPASS_MIN_RELEASE_AGE:-} != 1 ]]; then
    continue
  fi
  if [[ -z $best_ver ]] || [[ $(vercmp "$ver" "$best_ver") -gt 0 ]]; then
    best_ver=$ver best_tag=$tag best_at=$published_at
  fi
done < <(jq -r '.[] | select((.draft or .prerelease) | not) | [.tag_name, .published_at] | @tsv' <<<"$releases")

if [[ -z $best_ver ]] || [[ $(vercmp "$best_ver" "$current") -le 0 ]]; then
  echo '{}'
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

asset="signal-cli-${best_ver}-Linux-native.tar.gz"
base="https://github.com/$REPO/releases/download/$best_tag"
curl -fsSL -o "$work/$asset" "$base/$asset"
curl -fsSL -o "$work/$asset.asc" "$base/$asset.asc"

export GNUPGHOME="$work/gnupg"
mkdir -m700 "$GNUPGHOME"
gpg --batch --quiet --import keys/pgp/*.asc
if ! gpg --batch --quiet --verify "$work/$asset.asc" "$work/$asset" 2>"$work/gpg.log"; then
  echo "Signature check failed for $asset:" >&2
  cat "$work/gpg.log" >&2
  exit 1
fi

jq -n \
  --arg pkgver "$best_ver" \
  --arg published_at "$best_at" \
  --arg sha256 "$(sha256sum "$work/$asset" | cut -d' ' -f1)" \
  '{pkgver: $pkgver, published_at: $published_at, sha256sums: {x86_64: [$sha256]}}'
