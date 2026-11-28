#!/bin/bash
# cua-driver ships from the trycua/cua monorepo, whose single release feed
# interleaves many products (cua-driver-rs-v*, fleet-v*, sandbox-v*, and
# nightly-* builds) and exceeds GitHub's 1,000-release REST pagination cap.
# Enumerate cua-driver-rs-v* git tags directly (no pagination cap), walk from
# newest down via /releases/tags/<tag>, and read checksums.txt for the first
# stable non-draft release that clears MIN_RELEASE_AGE_SECONDS.
set -euo pipefail

REPO="trycua/cua"
TAG_PREFIX="cua-driver-rs-v"
CURL_OPTS=(--http1.1 --retry 3 --retry-max-time 60 --connect-timeout 20 --max-time 30)

ls_remote_out=$(timeout 60 git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=30 ls-remote --tags --refs "https://github.com/$REPO.git" "refs/tags/${TAG_PREFIX}*")

mapfile -t tags < <(
  awk -v p="refs/tags/$TAG_PREFIX" 'index($2, p) == 1 {
    v = substr($2, length(p) + 1)
    if (v ~ /^[0-9]+(\.[0-9]+)*$/) print v "\t" substr($2, 11)
  }' <<<"$ls_remote_out" |
    python3 -c '
import sys
rows = [line.rstrip("\n").split("\t", 1) for line in sys.stdin if line.strip()]
rows.sort(key=lambda r: tuple(int(x) for x in r[0].split(".")), reverse=True)
for v, tag in rows:
    print(f"{v}\t{tag}")
'
)

if (( ${#tags[@]} == 0 )); then
  echo "no stable $TAG_PREFIX releases in the feed for $REPO" >&2
  exit 1
fi

current=$(grep -m1 '^pkgver=' PKGBUILD | cut -d= -f2- | tr -d "\"'")
min_age="${MIN_RELEASE_AGE_SECONDS:-0}"
now=$(date +%s)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

quarantined=0
reached_current=0
best_pkgver="" best_tag="" best_published=""

for row in "${tags[@]}"; do
  IFS=$'\t' read -r pkgver tag <<<"$row"
  if [[ -n "$current" ]] && [[ "$(vercmp "$pkgver" "$current")" -le 0 ]]; then
    reached_current=1
    break
  fi

  body="$tmp/release.json"
  http_code=$(curl "${CURL_OPTS[@]}" -sSL -o "$body" -w '%{http_code}' \
    "https://api.github.com/repos/$REPO/releases/tags/$tag")
  if [[ "$http_code" == "404" ]]; then
    # Tag exists without a published GitHub release yet; keep walking down.
    continue
  fi
  if [[ "$http_code" != "200" ]]; then
    echo "GitHub release lookup failed for $REPO $tag (HTTP $http_code)" >&2
    exit 1
  fi

  if ! parsed=$(jq -er 'if type != "object" then error("expected release object") elif .draft == true then "__DRAFT__" else [.tag_name // "", .published_at // ""] | @tsv end' "$body"); then
    echo "invalid release JSON for $REPO $tag" >&2
    exit 1
  fi
  if [[ "$parsed" == "__DRAFT__" ]]; then
    continue
  fi

  IFS=$'\t' read -r got_tag published_at <<<"$parsed"
  if [[ "$got_tag" != "$tag" ]]; then
    echo "unexpected tag_name '$got_tag' for $REPO $tag" >&2
    exit 1
  fi

  # Strict ISO 8601 before GNU date sees it, matching bin/sync-upstream's
  # backstop: date alone also accepts relative expressions, which would let a
  # malformed feed fabricate an age instead of failing closed.
  if [[ ! "$published_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})$ ]] \
      || ! published_epoch=$(date --date="$published_at" +%s 2>/dev/null); then
    echo "$REPO release $tag has an invalid published_at: ${published_at:-<empty>}" >&2
    exit 1
  fi

  if (( now - published_epoch < min_age )); then
    if [[ "${BYPASS_MIN_RELEASE_AGE:-}" == "1" ]]; then
      echo "Bypassing release-age gate for $REPO $tag" >&2
    else
      quarantined=$((quarantined + 1))
      continue
    fi
  fi

  best_pkgver=$pkgver
  best_tag=$tag
  best_published=$published_at
  break
done

if [[ -z "$best_tag" ]]; then
  if (( quarantined > 0 )); then
    echo "every recent $TAG_PREFIX release is still inside the release-age quarantine; skipping" >&2
    echo '{}'
    exit 0
  fi
  if (( reached_current == 1 )); then
    echo '{}'
    exit 0
  fi
  echo "no stable $TAG_PREFIX releases in the feed for $REPO" >&2
  exit 1
fi

checksums=$(curl "${CURL_OPTS[@]}" -fsSL "https://github.com/$REPO/releases/download/$best_tag/checksums.txt")

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

jq -n \
  --arg pkgver "$best_pkgver" \
  --arg published_at "$best_published" \
  --argjson sha256sums "$sums_json" \
  '{pkgver: $pkgver, published_at: $published_at, sha256sums: $sha256sums}'
