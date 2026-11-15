#!/bin/bash
# Offline fixtures, also run by bin/sync-upstream self-test. Needs bash and jq.
set -euo pipefail
hook="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/upstream.sh"
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT
cd "$fixture_dir"
printf 'pkgver=1.0.0\npkgrel=1\n' > PKGBUILD
cp PKGBUILD PKGBUILD.before

failures=0
check() {
  if [[ "$2" == "$3" ]]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (expected '$2', got '$3')"
    failures=$((failures + 1))
  fi
}

curl() {
  local url="${!#}"
  printf '%s\n' "$url" >> "$REQUESTS"
  case "$url" in
    https://tmog.org/rtm/downloads/release-linux.json)
      printf '%s' "$MANIFEST"
      [[ "$FAIL_FETCH" != manifest ]]
      ;;
    https://tmog.org/rtm/downloads/TaskManagerOG-1.0.1-linux-x86_64.tar.gz.sha256)
      printf '%s' "$CHECKSUM"
      [[ "$FAIL_FETCH" != checksum ]]
      ;;
    *) echo "unexpected fixture URL: $url" >&2; return 22 ;;
  esac
}
export -f curl
export MANIFEST CHECKSUM FAIL_FETCH REQUESTS="$fixture_dir/requests"
FAIL_FETCH=''
sum=$(printf 'a%.0s' {1..64})
appimage_sum=$(printf 'b%.0s' {1..64})
artifact=TaskManagerOG-1.0.1-linux-x86_64.tar.gz
current_manifest=$(jq -cn --arg sha256 "$appimage_sum" \
  '{schemaVersion: 1, platform: "Linux", architecture: "x86_64", version: "1.0.0", sha256: $sha256}')
new_manifest=$(jq -c '.version = "1.0.1"' <<<"$current_manifest")
CHECKSUM="$sum  $artifact"

run_hook() {
  : > "$REQUESTS"
  status=0
  out=$(bash "$hook" 2>stderr) || status=$?
  check 'hook leaves the recipe untouched' yes "$(cmp -s PKGBUILD PKGBUILD.before && echo yes || echo no)"
}
expect_failure() {
  run_hook
  check "$1 fails closed" yes "$([[ "$status" != 0 ]] && echo yes || echo no)"
  check "$1 emits no update" '' "$out"
}

echo 'TMOG Linux release hook:'
# Regression: the shared version.txt can say 1.0.1 while Linux is still 1.0.0.
# Any attempt to fetch that shared feed (or a tarball) is rejected by curl().
MANIFEST="$current_manifest"
run_hook
check 'unchanged Linux release succeeds' 0 "$status"
check 'shared feed cannot advance Linux' '{}' "$out"
check 'unchanged release requests only its manifest' \
  'https://tmog.org/rtm/downloads/release-linux.json' "$(cat "$REQUESTS")"

MANIFEST="$new_manifest"
run_hook
check 'new Linux release succeeds without trailing checksum newline' 0 "$status"
check 'Linux version is reported' 1.0.1 "$(jq -r '.pkgver' <<<"$out")"
check 'tarball checksum, not AppImage checksum, is reported' "$sum" "$(jq -r '.sha256sums.any[0]' <<<"$out")"
check 'update requests only the manifest and its tarball sidecar' \
  "$(printf '%s\n' 'https://tmog.org/rtm/downloads/release-linux.json' "https://tmog.org/rtm/downloads/$artifact.sha256")" "$(cat "$REQUESTS")"

CHECKSUM="$sum *$artifact"$'\n'
run_hook
check 'binary-mode sidecar is accepted' 0 "$status"

for filter in '.schemaVersion = 2' '.platform = "macOS"' \
  '.architecture = "aarch64"' 'del(.architecture)' '.version = 1' \
  '.version = "1.0.1-rc1"' '.version = "1.0.1\n"' 'del(.version)'; do
  MANIFEST=$(jq -c "$filter" <<<"$new_manifest")
  expect_failure "invalid manifest ($filter)"
  check 'invalid manifest never requests a checksum' 1 "$(wc -l < "$REQUESTS" | tr -d ' ')"
done
for MANIFEST in '' 'not json' 'null' '[]'; do
  expect_failure "invalid manifest body ($MANIFEST)"
done

MANIFEST="$new_manifest"
FAIL_FETCH=manifest
expect_failure 'failed manifest fetch with a valid-looking partial body'
FAIL_FETCH=checksum
expect_failure 'failed checksum fetch with a valid-looking partial body'
FAIL_FETCH=''
for CHECKSUM in '' "invalid  $artifact" "$sum  TaskManagerOG-1.0.0-linux-x86_64.tar.gz" \
  "$sum  TaskManagerOG-1.0.1-linux-aarch64.tar.gz" "$sum  $artifact.extra"; do
  expect_failure 'missing or invalid tarball checksum'
done

[[ "$failures" == 0 ]]
