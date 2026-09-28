#!/bin/bash
# cua-driver ships from the trycua/cua monorepo, whose single release feed
# interleaves many products (cua-driver-rs-v*, fleet-v*, sandbox-v*, and
# nightly-* builds). The declarative github provider reads a feed as one
# product and stops on the first foreign tag, so this hook selects the newest
# stable cua-driver-rs release itself and reads its checksums.txt manifest.
set -euo pipefail

REPO="trycua/cua"
TAG_PREFIX="cua-driver-rs-v"

# Publication order is not version order: older pages can contain a newer
# driver version than a recently rebuilt release. Exhaust the feed before
# selecting, and fail closed if the bounded scan cannot reach its end.
releases='[]'
max_pages=100
for ((page = 1; page <= max_pages; page++)); do
  release_page=$(curl --connect-timeout 10 --max-time 30 -fsSL \
    "https://api.github.com/repos/$REPO/releases?per_page=100&page=$page")
  if ! page_size=$(jq -er 'if type == "array" and length <= 100 then length else error("expected release page of at most 100 entries") end' <<<"$release_page"); then
    echo "invalid release feed for $REPO on page $page" >&2
    exit 1
  fi
  releases=$(printf '%s\n' "$releases" "$release_page" | jq -cs 'add')
  (( page_size == 100 )) || break
done
if (( page > max_pages )); then
  echo "release feed for $REPO exceeds $max_pages pages; refusing incomplete selection" >&2
  exit 1
fi

# Keep jq failures in the main shell, where errexit can reject malformed data.
release_rows=$(jq -r '.[] | select(.draft | not) | [.tag_name // "", .published_at // ""] | @tsv' <<<"$releases")

min_age="${MIN_RELEASE_AGE_SECONDS:-0}"
now=$(date +%s)
candidates=0
best_pkgver="" best_tag="" best_published=""
while IFS=$'\t' read -r tag published_at; do
  [[ "$tag" == "$TAG_PREFIX"* ]] || continue
  pkgver=${tag#"$TAG_PREFIX"}
  # Upstream marks every driver release "prerelease" so the monorepo's
  # "latest" can point at another product; stability lives in the tag shape
  # instead. Stable driver versions are plain dotted numbers -- nightlies
  # carry a nightly- tag prefix and a -nightly.N version suffix, and both
  # fall out here.
  [[ "$pkgver" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue

  # Strict ISO 8601 before GNU date sees it, matching bin/sync-upstream's
  # backstop: date alone also accepts relative expressions, which would let a
  # malformed feed fabricate an age instead of failing closed.
  if [[ ! "$published_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})$ ]] \
      || ! published_epoch=$(date --date="$published_at" +%s 2>/dev/null); then
    echo "$REPO release $tag has an invalid published_at: ${published_at:-<empty>}" >&2
    exit 1
  fi
  candidates=$((candidates + 1))

  if (( now - published_epoch < min_age )); then
    if [[ "${BYPASS_MIN_RELEASE_AGE:-}" == "1" ]]; then
      echo "Bypassing release-age gate for $REPO $tag" >&2
    else
      continue
    fi
  fi

  if [[ -z "$best_pkgver" ]] || [[ "$(vercmp "$pkgver" "$best_pkgver")" -gt 0 ]]; then
    best_pkgver=$pkgver
    best_tag=$tag
    best_published=$published_at
  fi
done <<<"$release_rows"

# A feed with no stable driver release at all is an anomaly worth a loud
# error; every candidate merely being inside the quarantine window is not.
if (( candidates == 0 )); then
  echo "no stable $TAG_PREFIX releases in the feed for $REPO" >&2
  exit 1
fi
if [[ -z "$best_tag" ]]; then
  echo "every recent $TAG_PREFIX release is still inside the release-age quarantine; skipping" >&2
  echo '{}'
  exit 0
fi

current=$(grep -m1 '^pkgver=' PKGBUILD | cut -d= -f2- | tr -d "\"'")
if [[ -n "$current" ]] && [[ "$(vercmp "$best_pkgver" "$current")" -le 0 ]]; then
  echo '{}'
  exit 0
fi

checksums=$(curl -fsSL "https://github.com/$REPO/releases/download/$best_tag/checksums.txt")

sums_json='{}'
for arch in x86_64 aarch64; do
  case "$arch" in
    x86_64) platform="linux-x86_64" ;;
    aarch64) platform="linux-arm64" ;;
  esac
  asset="cua-driver-rs-${best_pkgver}-${platform}.tar.gz"
  sum=$(awk -v f="$asset" '$2 == f { print $1; exit }' <<<"$checksums")
  if [[ ! "$sum" =~ ^[0-9a-f]{64}$ ]]; then
    echo "no valid checksum for $asset in $REPO $best_tag checksums.txt" >&2
    exit 1
  fi
  sums_json=$(jq -c --arg arch "$arch" --arg sum "$sum" '.[$arch] = [$sum]' <<<"$sums_json")
done

jq -n --arg pkgver "$best_pkgver" --arg published_at "$best_published" \
  --argjson sums "$sums_json" \
  '{pkgver: $pkgver, published_at: $published_at, sha256sums: $sums}'
