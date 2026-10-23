#!/bin/bash
# The github provider's fetches: the release feed sends the job's token to
# api.github.com through curl's stdin config (never on a command line), the
# checksum download from github.com never gets it, and both stay on HTTP/1.1
# and retry transient errors with curl's backoff, with no retry after 60s
# and no attempt past 30s.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
source "$ROOT/helpers/upstream-github.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# Records the arguments and stdin, writes CURL_BODY to the -o file, and
# exits CURL_STATUS.
curl() {
  printf '%s\n' "$@" > "$T/args"
  cat > "$T/stdin"
  local args=("$@") i
  for ((i = 0; i < ${#args[@]}; i++)); do
    [[ ${args[i]} == -o ]] && printf '%s' "${CURL_BODY:-}" > "${args[i + 1]}"
  done
  return "${CURL_STATUS:-0}"
}

# Each flag followed by its value, as separate arguments.
retries() {
  local flag value
  for flag in --retry=3 --retry-max-time=60 --connect-timeout=20 --max-time=30; do
    value=${flag#*=}
    grep -A1 -x -- "${flag%%=*}" "$T/args" | tail -n +2 | grep -qx -- "$value" || return 1
  done
}

UPSTREAM_GITHUB_TOKEN=job-token github_fetch_releases owner/repo </dev/null
grep -qx 'https://api.github.com/repos/owner/repo/releases?per_page=100' "$T/args" \
  && pass "the release feed comes from the API" || fail "release feed URL: $(<"$T/args")"
grep -qx -- '--http1.1' "$T/args" && pass "the release feed uses HTTP/1.1" || fail "release feed args: $(<"$T/args")"
retries && pass "the release feed retries with a bounded backoff" || fail "release feed args: $(<"$T/args")"
grep -q job-token "$T/args" && fail "the token is on the command line"
pass "the token stays off the command line"
grep -A1 -x -- '--config' "$T/args" | grep -qx -- '-' \
  && [[ $(<"$T/stdin") == 'header = "Authorization: Bearer job-token"' ]] \
  && pass "the token goes to the API through stdin config" || fail "args: $(<"$T/args") stdin: $(<"$T/stdin")"

UPSTREAM_GITHUB_TOKEN= github_fetch_releases owner/repo </dev/null
grep -qx -- '--config' "$T/args" && fail "an empty token still reads a config"
[[ ! -s "$T/stdin" ]] && pass "no token, no Authorization header" || fail "stdin: $(<"$T/stdin")"
retries && pass "the anonymous release feed retries too" || fail "release feed args: $(<"$T/args")"

UPSTREAM_GITHUB_TOKEN=job-token github_fetch_checksums owner/repo v1.0 SHA256SUMS </dev/null
grep -qx 'https://github.com/owner/repo/releases/download/v1.0/SHA256SUMS' "$T/args" \
  && pass "checksums come from the release download" || fail "checksums URL: $(<"$T/args")"
grep -qx -- '--http1.1' "$T/args" && pass "the checksum download uses HTTP/1.1" || fail "checksum args: $(<"$T/args")"
retries && pass "the checksum download retries with a bounded backoff" || fail "checksum args: $(<"$T/args")"
grep -q job-token "$T/args" "$T/stdin" && fail "the token went to a release download"
pass "the token never goes to a release download"

# curl empties an -o file before each retry but cannot take back what a
# partial attempt already wrote to stdout, so the body has to go to a file
# and reach stdout only once the whole fetch succeeded.
out=$(CURL_BODY='[{"tag_name":"v1"}]' github_fetch_releases owner/repo </dev/null)
grep -A1 -x -- '-o' "$T/args" | tail -n +2 | grep -q . \
  && [[ $out == '[{"tag_name":"v1"}]' ]] \
  && pass "a fetch prints the body it downloaded to a file" || fail "output: $out args: $(<"$T/args")"
mkdir "$T/tmp"
status=0
out=$(TMPDIR="$T/tmp" CURL_BODY='[{"tag_n' CURL_STATUS=28 github_fetch_releases owner/repo </dev/null) || status=$?
(( status == 28 )) && [[ -z $out ]] \
  && pass "a failed fetch prints nothing and keeps curl's exit status" || fail "status $status, output: $out"
grep -A1 -x -- '-o' "$T/args" | tail -n +2 | grep -q "^$T/tmp/" && [[ -z $(ls -A "$T/tmp") ]] \
  && pass "the download file is removed" || fail "download file: $(ls -A "$T/tmp") args: $(<"$T/args")"
