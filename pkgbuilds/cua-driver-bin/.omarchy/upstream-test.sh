#!/bin/bash
# Offline hook fixtures, also run by bin/sync-upstream self-test. Requires
# GNU date, jq, python3, and pacman's vercmp, like the repository's other self-tests.
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

timeout() {
  shift
  "$@"
}
git() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "ls-remote" ]]; then
      [[ "${FAIL_GIT:-}" != 1 ]] || { echo 'fixture git ls-remote failure' >&2; return 128; }
      printf '%s\n' "$TAGS_OUTPUT"
      return 0
    fi
  done
  command git "$@"
}

curl() {
  local out_file="" write_code=0 url=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o) out_file="$2"; shift 2 ;;
      -w) write_code=1; shift 2 ;;
      --retry|--retry-max-time|--connect-timeout|--max-time) shift 2 ;;
      -*) shift ;;
      *) url="$1"; shift ;;
    esac
  done

  case "$url" in
    'https://api.github.com/repos/trycua/cua/releases/tags/'*)
      local tag="${url##*/}"
      [[ "$tag" != "${FAIL_TAG:-}" ]] || { echo 'fixture API failure' >&2; return 22; }
      local entry code body
      entry=$(jq -c --arg t "$tag" '.[$t] // empty' <<<"$RELEASES_BY_TAG")
      if [[ -z "$entry" ]]; then
        code="404"
        body='{"message":"Not Found"}'
      elif [[ "$(jq -r 'type' <<<"$entry")" == "object" ]] && jq -e 'has("__http_code")' <<<"$entry" >/dev/null; then
        code=$(jq -r '.__http_code' <<<"$entry")
        body=$(jq -r '.__body // "{}"' <<<"$entry")
      else
        code="200"
        body="$entry"
      fi
      if [[ -n "$out_file" ]]; then
        printf '%s\n' "$body" > "$out_file"
      else
        printf '%s\n' "$body"
      fi
      (( write_code == 1 )) && printf '%s' "$code"
      ;;
    'https://github.com/trycua/cua/releases/download/'*'/checksums.txt')
      [[ "${FAIL_CHECKSUMS:-}" != 1 ]] || { echo 'fixture download failure' >&2; return 22; }
      printf '%s\n' "$CHECKSUMS"
      ;;
    *) echo "unexpected fixture URL: $url" >&2; return 1 ;;
  esac
}
export -f curl date git timeout
export TAGS_OUTPUT RELEASES_BY_TAG CHECKSUMS FAIL_GIT FAIL_TAG FAIL_CHECKSUMS
export MIN_RELEASE_AGE_SECONDS=86400
export BYPASS_MIN_RELEASE_AGE=''
FAIL_GIT='' FAIL_TAG='' FAIL_CHECKSUMS=''

release() {
  jq -cn --arg tag "$1" --arg published "${2:-2026-09-06T16:51:50Z}" \
    '{tag_name: $tag, published_at: $published, draft: false, prerelease: true}'
}
tags_from() {
  local t
  for t in "$@"; do
    printf 'deadbeef\trefs/tags/%s\n' "$t"
  done
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
stable=$(release cua-driver-rs-v0.24.0 2026-09-07T16:51:50Z)

echo 'Cua Driver release hook:'
# Highest numeric version wins regardless of tag listing order (0.24.0 > 0.9.9 > 0.23.3).
TAGS_OUTPUT=$(tags_from cua-driver-rs-v0.9.9 cua-driver-rs-v0.23.3 cua-driver-rs-v0.24.0 fleet-v9.0.0)
RELEASES_BY_TAG=$(jq -cn --argjson s "$stable" '{"cua-driver-rs-v0.24.0": $s}')
run_hook
check 'tag enumeration selects highest stable version' 0 "$status"
check 'stable-shaped prerelease accepted at exactly 24h' 0.24.0 "$(jq -r '.pkgver' <<<"$out")"
check 'x86_64 checksum' "$sum_x" "$(jq -r '.sha256sums.x86_64[0]' <<<"$out")"
check 'ARM checksum' "$sum_a" "$(jq -r '.sha256sums.aarch64[0]' <<<"$out")"
check 'publication date preserved' 2026-09-07T16:51:50Z "$(jq -r '.published_at' <<<"$out")"

# Draft, unpublished tag (404), nightly tags, and young release are skipped in favor of 0.24.0.
draft=$(release cua-driver-rs-v99.0.0 | jq -c '.draft = true')
young=$(release cua-driver-rs-v0.25.0 2026-09-07T16:51:51Z)
TAGS_OUTPUT=$(tags_from cua-driver-rs-v99.0.0 cua-driver-rs-v98.0.0 nightly-cua-driver-rs-v99.0.0 cua-driver-rs-v99.0.0-nightly.1 cua-driver-rs-v0.25.0 cua-driver-rs-v0.24.0 cua-driver-rs-v0.23.3)
RELEASES_BY_TAG=$(jq -cn --argjson d "$draft" --argjson y "$young" --argjson s "$stable" \
  '{"cua-driver-rs-v99.0.0": $d, "cua-driver-rs-v0.25.0": $y, "cua-driver-rs-v0.24.0": $s}')
run_hook
check 'drafts/404s/nightlies rejected and young release quarantined' 0.24.0 "$(jq -r '.pkgver' <<<"$out")"

TAGS_OUTPUT=$(tags_from cua-driver-rs-v0.25.0 cua-driver-rs-v0.23.2)
RELEASES_BY_TAG=$(jq -cn --argjson y "$young" '{"cua-driver-rs-v0.25.0": $y}')
run_hook
check 'all newer candidates too young is a successful skip' 0 "$status"
check 'all young candidates emit empty JSON' '{}' "${out##*$'\n'}"
check 'quarantine reason is reported' yes "$([[ "$out" == *release-age* ]] && echo yes || echo no)"

TAGS_OUTPUT=$(tags_from cua-driver-rs-v0.23.2)
RELEASES_BY_TAG='{}'
run_hook
check 'current package version is unchanged' '{}' "$out"

TAGS_OUTPUT=$(tags_from cua-driver-rs-v99.0.0 nightly-cua-driver-rs-v99.0.0 cua-driver-rs-v99.0.0-nightly.1)
RELEASES_BY_TAG=$(jq -cn --argjson d "$draft" '{"cua-driver-rs-v99.0.0": $d}')
expect_failure 'no stable component candidate' 'no stable cua-driver-rs-v'

TAGS_OUTPUT=''
RELEASES_BY_TAG='{}'
expect_failure 'empty tag list' 'no stable cua-driver-rs-v'

TAGS_OUTPUT=$(tags_from cua-driver-rs-v0.24.0)
RELEASES_BY_TAG=$(jq -cn --argjson r "$(release cua-driver-rs-v0.24.0 yesterday)" '{"cua-driver-rs-v0.24.0": $r}')
expect_failure 'relative publication date' 'invalid published_at'
RELEASES_BY_TAG=$(jq -cn --argjson r "$(release cua-driver-rs-v0.24.0 2026-02-30T00:00:00Z)" '{"cua-driver-rs-v0.24.0": $r}')
expect_failure 'impossible publication date' 'invalid published_at'
RELEASES_BY_TAG='{"cua-driver-rs-v0.24.0":{"tag_name":"cua-driver-rs-v0.24.0","draft":false}}'
expect_failure 'missing publication date' 'invalid published_at'
RELEASES_BY_TAG='{"cua-driver-rs-v0.24.0":{"__http_code":"403","__body":"{\"message\":\"rate limit\"}"}}'
expect_failure 'HTTP 403 error fails closed' 'HTTP 403'
RELEASES_BY_TAG='{"cua-driver-rs-v0.24.0":{"__http_code":"200","__body":"not json"}}'
expect_failure 'malformed JSON fails closed' 'invalid release JSON'

FAIL_GIT=1
expect_failure 'git ls-remote failure' 'fixture git ls-remote failure'
FAIL_GIT=''
FAIL_TAG=cua-driver-rs-v0.24.0
expect_failure 'network failure on tag lookup' 'fixture API failure'
FAIL_TAG=''

RELEASES_BY_TAG=$(jq -cn --argjson s "$stable" '{"cua-driver-rs-v0.24.0": $s}')
FAIL_CHECKSUMS=1
expect_failure 'checksum download failure' 'fixture download failure'
FAIL_CHECKSUMS=''
CHECKSUMS="$sum_x  cua-driver-rs-0.24.0-linux-x86_64.tar.gz"
expect_failure 'missing ARM checksum' 'no valid checksum'
CHECKSUMS='invalid  cua-driver-rs-0.24.0-linux-x86_64.tar.gz'
expect_failure 'invalid checksum' 'no valid checksum'

[[ "$failures" == 0 ]]
