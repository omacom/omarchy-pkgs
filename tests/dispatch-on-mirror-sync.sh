#!/bin/bash
# Self-test for ci/dispatch-on-mirror-sync.sh: monotonic numeric lastsync
# handling, CDN cache bypass headers, bounded timeouts/retries, flock
# serialization, atomic state replacement, and fail-closed error handling.
# curl, date, timeout, and dispatch.sh are stubbed in a temp dir so nothing
# touches the network or repo checkout.
set -euo pipefail

ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin" "$T/ci" "$T/state"
cp "$ROOT/ci/dispatch-on-mirror-sync.sh" "$T/ci/dispatch-on-mirror-sync.sh"
chmod +x "$T/ci/dispatch-on-mirror-sync.sh"

# Freeze clock for deterministic future-skew boundary tests.
FIXED_NOW=1800000000
cat >"$T/bin/date" <<STUB
#!/bin/bash
echo "$FIXED_NOW"
STUB
chmod +x "$T/bin/date"

# Record timeout arguments and run the wrapped command (or simulate exit 124).
REAL_TIMEOUT=$(command -v timeout)
cat >"$T/bin/timeout" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >"\$STUB_DIR/timeout-args"
if [[ -n \${STUB_TIMEOUT_EXPIRE:-} ]]; then
  exit 124
fi
exec "$REAL_TIMEOUT" "\$@"
STUB
chmod +x "$T/bin/timeout"

# Signal when a process attempts to acquire flock, then exec real flock.
REAL_FLOCK=$(command -v flock)
cat >"$T/bin/flock" <<STUB
#!/bin/bash
if [[ -n \${STUB_FLOCK_ENTER_MARKER:-} ]]; then
  : >"\$STUB_FLOCK_ENTER_MARKER"
fi
exec "$REAL_FLOCK" "\$@"
STUB
chmod +x "$T/bin/flock"

cat >"$T/bin/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >"$STUB_DIR/curl-args"
out=""
retries=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|-o) out=$2; shift 2 ;;
    --retry) retries=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n ${STUB_CURL_EXIT:-} && ${STUB_CURL_EXIT} != 0 ]]; then
  echo "curl: (22) The requested URL returned error: 503" >&2
  exit "$STUB_CURL_EXIT"
fi
write_body() {
  if [[ -n ${STUB_CURL_BODY_FILE:-} ]]; then
    cat "$STUB_CURL_BODY_FILE"
  else
    printf '%s' "${STUB_CURL_BODY-}"
  fi
}
if [[ -n ${STUB_CURL_PARTIAL:-} ]]; then
  if (( retries < 1 )); then
    echo "curl: (28) Operation timed out" >&2
    exit 28
  fi
  if [[ -n $out ]]; then
    printf '%s' "$STUB_CURL_PARTIAL" >"$out"
    write_body >"$out"
  else
    printf '%s' "$STUB_CURL_PARTIAL"
    write_body
  fi
elif [[ -n $out ]]; then
  write_body >"$out"
else
  write_body
fi
STUB
chmod +x "$T/bin/curl"

cat >"$T/ci/dispatch.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB_DIR/dispatch-calls"
if [[ -n ${STUB_DISPATCH_RECORD_STATE:-} ]]; then
  cat "$STATE_DIRECTORY/mirror-lastsync" >"$STUB_DIR/state-during-dispatch" 2>/dev/null || true
  tmp_file=$(find "$STATE_DIRECTORY" -maxdepth 1 -name ".mirror-lastsync.tmp.*" | head -n 1)
  if [[ -n $tmp_file ]]; then
    stat -c %i "$tmp_file" >"$STUB_DIR/tmp-inode-during-dispatch"
  fi
fi
if [[ -n ${STUB_DISPATCH_ENTER_MARKER:-} ]]; then
  : >"$STUB_DISPATCH_ENTER_MARKER"
fi
if [[ -n ${STUB_DISPATCH_RELEASE_MARKER:-} ]]; then
  while [[ ! -e $STUB_DISPATCH_RELEASE_MARKER ]]; do
    sleep 0.01
  done
fi
exit "${STUB_DISPATCH_EXIT:-0}"
STUB
chmod +x "$T/ci/dispatch.sh"

export PATH="$T/bin:$PATH"
export STUB_DIR=$T
export MIRROR=https://mirror.omarchy.org

T_OLD=$((FIXED_NOW - 14400))
T_1=$((FIXED_NOW - 10800))
T_2=$((FIXED_NOW - 7200))
T_3=$((FIXED_NOW - 5400))
T_4=$((FIXED_NOW - 3600))
T_5=$((FIXED_NOW - 1800))
T_6=$((FIXED_NOW - 600))
T_7=$((FIXED_NOW - 300))
T_FUTURE_EDGE=$((FIXED_NOW + 86400))
T_FUTURE_OVER=$((FIXED_NOW + 86401))
T_FUTURE=$((FIXED_NOW + 172800))
T_MILLIS=$((FIXED_NOW * 1000))

run_sync() {
  rm -f "$T/curl-args" "$T/timeout-args" "$T/dispatch-calls" "$T/stdout" "$T/stderr" \
    "$T/state-during-dispatch" "$T/tmp-inode-during-dispatch"
  set +e
  STATE_DIRECTORY="${1:-$T/state}" \
    "$T/ci/dispatch-on-mirror-sync.sh" >"$T/stdout" 2>"$T/stderr"
  RC=$?
  set -e
}

dispatch_count() {
  if [[ -f $T/dispatch-calls ]]; then
    wc -l <"$T/dispatch-calls" | tr -d " "
  else
    echo 0
  fi
}

stray_temps() {
  find "$T/state" -maxdepth 1 -name ".mirror-lastsync.tmp.*" | wc -l | tr -d " "
}

assert_curl_arg_pair() {
  local flag=$1 want=$2 got
  got=$(awk -v f="$flag" '$0 == f { getline; print; exit }' "$T/curl-args")
  [[ $got == "$want" ]] || fail "curl $flag was '$got', want '$want'"
}

# 1. First run: newer positive timestamp dispatches once, seeds state, sends no-cache + timeout -k
STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_1"$'\n' STUB_DISPATCH_EXIT=0 run_sync
[[ $RC -eq 0 ]] || fail "first run exited $RC: $(cat "$T/stderr")"
[[ $(dispatch_count) -eq 1 ]] || fail "first run dispatch count $(dispatch_count), want 1"
[[ $(cat "$T/dispatch-calls") == "sync-rebuilds" ]] || fail "unexpected dispatch arg: $(cat "$T/dispatch-calls")"
[[ $(cat "$T/state/mirror-lastsync") == "$T_1" ]] || fail "first run state: $(cat "$T/state/mirror-lastsync" 2>/dev/null || true)"
[[ $(stray_temps) -eq 0 ]] || fail "first run left temp files"
grep -qx -- "-fsS" "$T/curl-args" || fail "curl missing -fsS"
assert_curl_arg_pair "-H" "Cache-Control: no-cache"
assert_curl_arg_pair "--connect-timeout" "10"
assert_curl_arg_pair "--max-time" "15"
assert_curl_arg_pair "--retry" "2"
assert_curl_arg_pair "--retry-delay" "1"
assert_curl_arg_pair "--retry-max-time" "20"
grep -qx -- "--output" "$T/curl-args" || fail "curl missing --output temp file"
grep -qx -- "https://mirror.omarchy.org/lastsync?$FIXED_NOW" "$T/curl-args" \
  || fail "curl missing cache-busting query string: $(tr '\n' ' ' <"$T/curl-args")"
[[ $(head -n 3 "$T/timeout-args" | paste -sd" ") == "-k 5 30" ]] \
  || fail "dispatch missing timeout -k 5 30: $(tr '\n' ' ' <"$T/timeout-args")"
pass "first run dispatches once under timeout -k 5 30, writes state, and sends Cache-Control: no-cache"

# 2. Same timestamp does not dispatch
STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_1"$'\n' STUB_DISPATCH_EXIT=0 run_sync
[[ $RC -eq 0 ]] || fail "same timestamp exited $RC"
[[ $(dispatch_count) -eq 0 ]] || fail "same timestamp dispatched $(dispatch_count) times"
[[ $(cat "$T/state/mirror-lastsync") == "$T_1" ]] || fail "same timestamp altered state"
pass "same timestamp does not dispatch"

# 3. CDN skew ping-pong: older timestamp neither dispatches nor rolls back state
STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_OLD"$'\n' STUB_DISPATCH_EXIT=0 run_sync
[[ $RC -eq 0 ]] || fail "older timestamp exited $RC"
[[ $(dispatch_count) -eq 0 ]] || fail "older timestamp triggered dispatch"
[[ $(cat "$T/state/mirror-lastsync") == "$T_1" ]] \
  || fail "older timestamp rolled back state to $(cat "$T/state/mirror-lastsync")"
STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_1"$'\n' STUB_DISPATCH_EXIT=0 run_sync
[[ $RC -eq 0 && $(dispatch_count) -eq 0 ]] \
  || fail "poll after stale edge ping-ponged (rc=$RC, dispatches=$(dispatch_count))"
pass "older CDN timestamp does not dispatch, roll back state, or ping-pong"

# 4. Strictly newer timestamp stages temp file, dispatches, and atomically renames staged inode into place
inode_before=$(stat -c %i "$T/state/mirror-lastsync")
STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_2"$'\n' STUB_DISPATCH_EXIT=0 STUB_DISPATCH_RECORD_STATE=1 run_sync
inode_after=$(stat -c %i "$T/state/mirror-lastsync")
staged_inode=$(cat "$T/tmp-inode-during-dispatch" 2>/dev/null || true)
[[ $RC -eq 0 ]] || fail "newer timestamp exited $RC"
[[ $(dispatch_count) -eq 1 ]] || fail "newer timestamp dispatch count $(dispatch_count)"
[[ $(cat "$T/state-during-dispatch") == "$T_1" ]] \
  || fail "state was modified before dispatch finished: $(cat "$T/state-during-dispatch")"
[[ -n $staged_inode ]] || fail "temp state file was not staged before dispatch"
[[ $(cat "$T/state/mirror-lastsync") == "$T_2" ]] || fail "newer timestamp did not advance state"
[[ $inode_before != "$inode_after" && $inode_after == "$staged_inode" ]] \
  || fail "state inode did not match staged temp inode (before=$inode_before staged=$staged_inode after=$inode_after)"
[[ $(stray_temps) -eq 0 ]] || fail "newer timestamp left temp files"
pass "newer timestamp stages temp file, dispatches, and renames staged inode atomically"

# 5. Partial-transfer retry via --output overwrites instead of concatenating
STUB_CURL_EXIT=0 STUB_CURL_PARTIAL="1795" STUB_CURL_BODY="$T_3"$'\n' STUB_DISPATCH_EXIT=0 run_sync
[[ $RC -eq 0 && $(dispatch_count) -eq 1 ]] || fail "partial retry test failed (rc=$RC)"
[[ $(cat "$T/state/mirror-lastsync") == "$T_3" ]] \
  || fail "partial retry poisoned state: $(cat "$T/state/mirror-lastsync")"
pass "partial-transfer retry overwrites --output file instead of concatenating"

# 6. Dispatch failure and timeout expiration preserve previous state and clean temp file; retry succeeds
STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_4"$'\n' STUB_DISPATCH_EXIT=1 run_sync
[[ $RC -ne 0 ]] || fail "dispatch failure exited 0"
[[ $(dispatch_count) -eq 1 ]] || fail "dispatch failure count $(dispatch_count)"
[[ $(cat "$T/state/mirror-lastsync") == "$T_3" ]] \
  || fail "dispatch failure overwrote state to $(cat "$T/state/mirror-lastsync")"
[[ $(stray_temps) -eq 0 ]] || fail "dispatch failure left temp files"
STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_4"$'\n' STUB_TIMEOUT_EXPIRE=1 run_sync
[[ $RC -eq 124 ]] || fail "dispatch timeout exited $RC, want 124"
[[ $(cat "$T/state/mirror-lastsync") == "$T_3" ]] \
  || fail "dispatch timeout overwrote state to $(cat "$T/state/mirror-lastsync")"
[[ $(stray_temps) -eq 0 ]] || fail "dispatch timeout left temp files"
STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_4"$'\n' STUB_DISPATCH_EXIT=0 run_sync
[[ $RC -eq 0 && $(dispatch_count) -eq 1 && $(cat "$T/state/mirror-lastsync") == "$T_4" ]] \
  || fail "retry after dispatch failure/timeout did not succeed cleanly"
pass "dispatch failure and timeout expiration preserve state and clean temp file so retry works"

# 7. Invalid, HTTP 5xx, zero, malformed, oversized, NUL-byte, and future values fail closed
for case_spec in \
  "html:0:<html><body>502 Bad Gateway</body></html>" \
  "empty:0:" \
  "http-503:22:" \
  "zero:0:0" \
  "trailing-space:0:$T_5 " \
  "multiline:0:$T_5"$'\n'"$T_6" \
  "future-over-by-1s:0:$T_FUTURE_OVER" \
  "future:0:$T_FUTURE" \
  "millis:0:$T_MILLIS" \
  "huge18:0:999999999999999999" \
  "overflow:0:99999999999999999999"; do
  label=${case_spec%%:*}
  rest=${case_spec#*:}
  cexit=${rest%%:*}
  cbody=${rest#*:}
  STUB_CURL_EXIT=$cexit STUB_CURL_BODY=$cbody STUB_DISPATCH_EXIT=0 run_sync
  [[ $RC -ne 0 ]] || fail "bad response ($label) unexpectedly exited 0"
  [[ $(dispatch_count) -eq 0 ]] || fail "bad response ($label) triggered dispatch"
  [[ $(cat "$T/state/mirror-lastsync") == "$T_4" ]] \
    || fail "bad response ($label) corrupted state"
done
printf '1795\000875000\n' >"$T/nul-body"
STUB_CURL_EXIT=0 STUB_CURL_BODY_FILE="$T/nul-body" STUB_DISPATCH_EXIT=0 run_sync
[[ $RC -ne 0 && $(dispatch_count) -eq 0 && $(cat "$T/state/mirror-lastsync") == "$T_4" ]] \
  || fail "NUL byte response did not fail closed"
pass "HTML, empty, HTTP 5xx, zero, malformed, NUL-byte, future+1s, and oversized responses fail closed"

# 8. Leading-zero numeric values do not trigger bash octal errors
STUB_CURL_EXIT=0 STUB_CURL_BODY="0$T_4"$'\n' STUB_DISPATCH_EXIT=0 run_sync
[[ $RC -eq 0 && $(dispatch_count) -eq 0 ]] || fail "leading-zero equal failed (rc=$RC)"
STUB_CURL_EXIT=0 STUB_CURL_BODY="0$T_5"$'\n' STUB_DISPATCH_EXIT=0 run_sync
[[ $RC -eq 0 && $(dispatch_count) -eq 1 && $(cat "$T/state/mirror-lastsync") == "$T_5" ]] \
  || fail "leading-zero newer failed (rc=$RC, state=$(cat "$T/state/mirror-lastsync"))"
pass "leading-zero timestamps compare in base-10 without octal errors"

# 9. Overlapping invocations serialize deterministically via flock so only one dispatches
rm -f "$T/dispatch-calls" "$T/dispatch1-entered" "$T/release-dispatch1" "$T/flock2-entered"
STATE_DIRECTORY="$T/state" STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_6"$'\n' STUB_DISPATCH_EXIT=0 \
  STUB_DISPATCH_ENTER_MARKER="$T/dispatch1-entered" \
  STUB_DISPATCH_RELEASE_MARKER="$T/release-dispatch1" \
  "$T/ci/dispatch-on-mirror-sync.sh" >"$T/stdout1" 2>"$T/stderr1" &
pid1=$!
for _ in $(seq 1 200); do
  [[ -e $T/dispatch1-entered ]] && break
  sleep 0.01
done
[[ -e $T/dispatch1-entered ]] || fail "first overlapping run never entered dispatch"
STATE_DIRECTORY="$T/state" STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_6"$'\n' STUB_DISPATCH_EXIT=0 \
  STUB_FLOCK_ENTER_MARKER="$T/flock2-entered" \
  "$T/ci/dispatch-on-mirror-sync.sh" >"$T/stdout2" 2>"$T/stderr2" &
pid2=$!
for _ in $(seq 1 200); do
  [[ -e $T/flock2-entered ]] && break
  sleep 0.01
done
[[ -e $T/flock2-entered ]] || fail "second overlapping run never attempted flock"
sleep 0.02
kill -0 "$pid2" 2>/dev/null || fail "second overlapping run did not block on held flock"
[[ $(dispatch_count) -eq 1 ]] || fail "second overlapping run dispatched before lock release"
: >"$T/release-dispatch1"
wait "$pid1" "$pid2"
[[ $(dispatch_count) -eq 1 && $(cat "$T/state/mirror-lastsync") == "$T_6" ]] \
  || fail "overlapping runs were not serialized (dispatches=$(dispatch_count))"
pass "overlapping invocations serialize deterministically via flock and dispatch once"

# 10. Corrupt, empty, NUL-byte, future-poisoned, directory, or symlink state files fail closed
printf 'not-a-timestamp\n' >"$T/state/mirror-lastsync"
STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_7"$'\n' STUB_DISPATCH_EXIT=0 run_sync
[[ $RC -ne 0 && $(dispatch_count) -eq 0 ]] || fail "corrupt state file did not fail closed"
[[ $(cat "$T/state/mirror-lastsync") == "not-a-timestamp" ]] || fail "corrupt state was overwritten"

: >"$T/state/mirror-lastsync"
STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_7"$'\n' STUB_DISPATCH_EXIT=0 run_sync
[[ $RC -ne 0 && $(dispatch_count) -eq 0 ]] || fail "empty state file did not fail closed"

printf '1795\000875000\n' >"$T/state/mirror-lastsync"
STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_7"$'\n' STUB_DISPATCH_EXIT=0 run_sync
[[ $RC -ne 0 && $(dispatch_count) -eq 0 ]] || fail "NUL-byte state file did not fail closed"

printf '%s\n' "$T_MILLIS" >"$T/state/mirror-lastsync"
STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_7"$'\n' STUB_DISPATCH_EXIT=0 run_sync
[[ $RC -ne 0 && $(dispatch_count) -eq 0 ]] || fail "out-of-range future state did not fail closed"
[[ $(cat "$T/state/mirror-lastsync") == "$T_MILLIS" ]] || fail "out-of-range state was overwritten"

rm -f "$T/state/mirror-lastsync"
ln -s "$T/no-such-target" "$T/state/mirror-lastsync"
STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_7"$'\n' STUB_DISPATCH_EXIT=0 run_sync
[[ $RC -ne 0 && $(dispatch_count) -eq 0 ]] || fail "dangling symlink state did not fail closed"

rm -f "$T/state/mirror-lastsync"
printf '%s\n' "$T_4" >"$T/real-target"
ln -s "$T/real-target" "$T/state/mirror-lastsync"
STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_7"$'\n' STUB_DISPATCH_EXIT=0 run_sync
[[ $RC -ne 0 && $(dispatch_count) -eq 0 ]] || fail "valid symlink state did not fail closed"
[[ $(cat "$T/real-target") == "$T_4" ]] || fail "symlink target was modified"

rm -f "$T/state/mirror-lastsync"
mkdir "$T/state/mirror-lastsync"
STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_7"$'\n' STUB_DISPATCH_EXIT=0 run_sync
[[ $RC -ne 0 && $(dispatch_count) -eq 0 ]] || fail "directory state path did not fail closed"
rmdir "$T/state/mirror-lastsync"
pass "corrupt, empty, NUL-byte, out-of-range, symlink, and directory state paths fail closed"

# 11. Missing state directory fails before dispatching
STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_7"$'\n' STUB_DISPATCH_EXIT=0 run_sync "$T/missing-state-dir"
[[ $RC -ne 0 && $(dispatch_count) -eq 0 ]] \
  || fail "missing state directory still dispatched (rc=$RC, dispatches=$(dispatch_count))"
pass "missing state directory fails before dispatching"

# 12. Trailing slash in MIRROR is normalized cleanly and exact future-skew boundary is accepted
MIRROR=https://mirror.omarchy.org/ STUB_CURL_EXIT=0 STUB_CURL_BODY="$T_FUTURE_EDGE"$'\n' STUB_DISPATCH_EXIT=0 run_sync
[[ $RC -eq 0 && $(dispatch_count) -eq 1 && $(cat "$T/state/mirror-lastsync") == "$T_FUTURE_EDGE" ]] \
  || fail "trailing slash / skew boundary failed (rc=$RC)"
grep -qx -- "https://mirror.omarchy.org/lastsync?$FIXED_NOW" "$T/curl-args" \
  || fail "trailing slash produced malformed URL: $(tr '\n' ' ' <"$T/curl-args")"
pass "trailing slash in MIRROR and exact future-skew boundary work cleanly"
