#!/bin/bash
# Offline hook fixtures, also run by bin/sync-upstream self-test. Requires
# GNU date, jq, and pacman's vercmp, like the repository's other self-tests.
set -euo pipefail
hook="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/upstream.sh"
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT
printf 'pkgver=0.23.2\n' > "$fixture_dir/PKGBUILD"
cd "$fixture_dir"

failures=0
check() {
  if [[ "$2" == "$3" ]]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (expected '$2', got '$3')"
    failures=$((failures + 1))
  fi
}

# Freeze time at the exact 24-hour boundary of the fixture's 0.24.0.
date() {
  if [[ "$*" == '+%s' ]]; then
    jq -nr '"2026-09-08T16:51:50Z" | fromdateiso8601'
  else
    command date "$@"
  fi
}
curl() {
  local url="${!#}"
  case "$url" in
    'https://api.github.com/repos/trycua/cua/releases?per_page=100&page='*)
      local page="${url##*=}"
      [[ "$page" != "${FAIL_PAGE:-}" ]] || { echo 'fixture API failure' >&2; return 22; }
      if [[ "${ENDLESS:-}" == 1 || "$page" == 1 ]]; then
        if [[ "${LARGE_PAGE:-}" == 1 ]]; then
          jq -c '.[0].body = ("x" * 131072)' <<<"$PAGE1"
        else
          printf '%s\n' "$PAGE1"
        fi
      elif [[ "$page" == 2 ]]; then
        printf '%s\n' "$PAGE2"
      else
        echo '[]'
      fi
      ;;
    'https://github.com/trycua/cua/releases/download/'*'/checksums.txt')
      [[ "${FAIL_CHECKSUMS:-}" != 1 ]] || { echo 'fixture download failure' >&2; return 22; }
      printf '%s\n' "$CHECKSUMS"
      ;;
    *) echo "unexpected fixture URL: $url" >&2; return 1 ;;
  esac
}
export -f curl date
export PAGE1 PAGE2 CHECKSUMS FAIL_PAGE FAIL_CHECKSUMS ENDLESS LARGE_PAGE
export MIN_RELEASE_AGE_SECONDS=86400
export BYPASS_MIN_RELEASE_AGE=''
FAIL_PAGE='' FAIL_CHECKSUMS='' ENDLESS='' LARGE_PAGE=''
PAGE2='[]'

release() {
  jq -cn --arg tag "$1" --arg published "${2:-2026-09-06T16:51:50Z}" \
    '{tag_name: $tag, published_at: $published, draft: false, prerelease: true}'
}
run_hook() {
  status=0
  out=$(bash "$hook" 2>&1) || status=$?
}
expect_failure() {
  run_hook
  check "$1 fails" yes "$([[ "$status" != 0 ]] && echo yes || echo no)"
  check "$1 reports the reason" yes "$([[ "$out" == *"$2"* ]] && echo yes || echo no)"
}
sum_x=$(printf 'a%.0s' {1..64})
sum_a=$(printf 'b%.0s' {1..64})
CHECKSUMS=$(printf '%s\n' \
  "$sum_x  cua-driver-rs-0.24.0-linux-x86_64.tar.gz" \
  "$sum_a  cua-driver-rs-0.24.0-linux-arm64.tar.gz")
foreign_page=$(jq -cn '[range(100) | {tag_name: "fleet-v9.0.0", draft: false}]')
stable=$(release cua-driver-rs-v0.24.0 2026-09-07T16:51:50Z)

echo 'Cua Driver release hook:'
PAGE1="$foreign_page"
PAGE2="[$stable]"
run_hook
check 'component found beyond the first 100 releases' 0 "$status"
check 'stable-shaped prerelease accepted at exactly 24h' 0.24.0 "$(jq -r '.pkgver' <<<"$out")"
check 'x86_64 checksum' "$sum_x" "$(jq -r '.sha256sums.x86_64[0]' <<<"$out")"
check 'ARM checksum' "$sum_a" "$(jq -r '.sha256sums.aarch64[0]' <<<"$out")"
check 'publication date preserved' 2026-09-07T16:51:50Z "$(jq -r '.published_at' <<<"$out")"

LARGE_PAGE=1
run_hook
check 'release page larger than the argument limit succeeds' 0 "$status"
check 'large release page preserves version selection' 0.24.0 "$(jq -r '.pkgver' <<<"$out")"
LARGE_PAGE=''

# An eligible lower version on page one must not terminate the scan.
rebuilt=$(release cua-driver-rs-v0.23.3 2026-09-07T16:51:50Z)
PAGE1=$(jq -c --argjson rebuilt "$rebuilt" '.[0] = $rebuilt' <<<"$foreign_page")
PAGE2="[$(release cua-driver-rs-v0.24.0)]"
run_hook
check 'older page outranks recently rebuilt lower version' 0.24.0 "$(jq -r '.pkgver' <<<"$out")"

draft=$(release cua-driver-rs-v99.0.0 | jq -c '.draft = true')
nightly=$(release nightly-cua-driver-rs-v99.0.0)
suffix=$(release cua-driver-rs-v99.0.0-nightly.1)
young=$(release cua-driver-rs-v0.25.0 2026-09-07T16:51:51Z)
PAGE1="[$draft,$nightly,$suffix,$young,$stable,$rebuilt]"
PAGE2='[]'
run_hook
check 'drafts/nightlies rejected and young release quarantined' 0.24.0 "$(jq -r '.pkgver' <<<"$out")"

PAGE1="[$young]"
run_hook
check 'all candidates too young is a successful skip' 0 "$status"
check 'all young candidates emit empty JSON' '{}' "${out##*$'\n'}"
check 'quarantine reason is reported' yes "$([[ "$out" == *release-age* ]] && echo yes || echo no)"

PAGE1="[$(release cua-driver-rs-v0.23.2)]"
run_hook
check 'current package version is unchanged' '{}' "$out"

PAGE1="[$draft,$nightly,$suffix]"
expect_failure 'no stable component candidate' 'no stable cua-driver-rs-v'
PAGE1='[]'
expect_failure 'empty feed' 'no stable cua-driver-rs-v'
PAGE1="[$(release cua-driver-rs-v0.24.0 yesterday)]"
expect_failure 'relative publication date' 'invalid published_at'
PAGE1="[$(release cua-driver-rs-v0.24.0 2026-02-30T00:00:00Z)]"
expect_failure 'impossible publication date' 'invalid published_at'
PAGE1='[{"tag_name":"cua-driver-rs-v0.24.0","draft":false}]'
expect_failure 'missing publication date' 'invalid published_at'

PAGE1="$foreign_page"
PAGE2='{"message":"API rate limit exceeded"}'
expect_failure 'API error object on later page' 'invalid release feed'
PAGE2='not json'
expect_failure 'malformed JSON on later page' 'invalid release feed'
PAGE2='[42]'
expect_failure 'malformed release entry' 'Cannot index'
PAGE2="[$stable]"
FAIL_PAGE=2
expect_failure 'network failure after first page' 'fixture API failure'
FAIL_PAGE=''
ENDLESS=1
expect_failure 'feed exceeds pagination bound' 'refusing incomplete selection'
ENDLESS=''

PAGE1="[$stable]"
PAGE2='[]'
FAIL_CHECKSUMS=1
expect_failure 'checksum download failure' 'fixture download failure'
FAIL_CHECKSUMS=''
CHECKSUMS="$sum_x  cua-driver-rs-0.24.0-linux-x86_64.tar.gz"
expect_failure 'missing ARM checksum' 'no valid checksum'
CHECKSUMS='invalid  cua-driver-rs-0.24.0-linux-x86_64.tar.gz'
expect_failure 'invalid checksum' 'no valid checksum'

[[ "$failures" == 0 ]]
