#!/bin/bash
# Every package's .omarchy/package.json passes validate_package_metadata,
# a fast-ring package that declares rebuild_on is refused (the fast ring
# ships one edge build to every channel, so nothing rebuilds it when a
# dependency moves), and so is the retired channels key. "review" is a
# boolean for a package with an upstream watch, and never with auto_merge.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
source "$ROOT/helpers/package-metadata.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

workers=$(nproc 2>/dev/null || echo 1)
if [[ -r /sys/fs/cgroup/cpu.max ]]; then
  read -r quota period < /sys/fs/cgroup/cpu.max || true
  if [[ "${quota:-max}" != "max" && -n "${period:-}" && "$period" -gt 0 ]]; then
    q=$(( (quota + period - 1) / period ))
    (( q < 1 )) && q=1
    (( q < workers )) && workers=$q
  fi
fi
pkgdirs=("$ROOT"/pkgbuilds/*/)
pids=()
for (( w = 0; w < workers; w++ )); do
  (
    for (( i = w; i < ${#pkgdirs[@]}; i += workers )); do
      if ! out=$(validate_package_metadata "${pkgdirs[i]%/}" 2>&1); then
        printf '%s\n' "${out:-${pkgdirs[i]%/}: validation failed}"
      fi
    done
  ) > "$T/invalid-$w" &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
mapfile -t invalid < <(cat "$T"/invalid-* | sed '/^$/d')
(( ${#invalid[@]} == 0 )) && pass "every package's metadata is valid" || fail "$(printf '%s; ' "${invalid[@]}")"

mkdir -p "$T/fast-rebuild/.omarchy"
echo '{"source": "local", "release_ring": "fast", "rebuild_on": ["qt6-base"]}' > "$T/fast-rebuild/.omarchy/package.json"
out=$(validate_package_metadata "$T/fast-rebuild" 2>&1) && fail "fast ring with rebuild_on accepted"
[[ $out == *"cannot be on the fast ring"* ]] && pass "fast ring with rebuild_on is refused" || fail "unexpected message: $out"

mkdir -p "$T/slow-rebuild/.omarchy"
echo '{"source": "local", "rebuild_on": ["qt6-base"]}' > "$T/slow-rebuild/.omarchy/package.json"
validate_package_metadata "$T/slow-rebuild" >/dev/null && pass "rebuild_on off the fast ring is fine" || fail "rebuild_on alone refused"

# The release ring is the only say a package has in where it publishes; a
# leftover channels list would look like a restriction and enforce nothing.
mkdir -p "$T/channels/.omarchy"
echo '{"source": "local", "channels": ["edge"]}' > "$T/channels/.omarchy/package.json"
out=$(validate_package_metadata "$T/channels" 2>&1) && fail "a channels key was accepted"
[[ $out == *"channels is gone"* ]] && pass "a channels key is refused" || fail "unexpected message: $out"

watch='"upstream": {"watch": {"git_tags": "https://example.com/x.git", "pattern": "v(?P<version>[0-9.]+)"}}'
review() { # review <name> <json>: validate a package declaring it
  mkdir -p "$T/$1/.omarchy"; echo "$2" > "$T/$1/.omarchy/package.json"
  validate_package_metadata "$T/$1" 2>&1
}
review reviewed "{\"source\": \"local\", \"review\": true, $watch}" >/dev/null &&
  pass "review with an upstream watch is fine" || fail "review with a watch refused"
out=$(review review-string "{\"source\": \"local\", \"review\": \"yes\", $watch}") && fail "a string review accepted"
[[ $out == *"review"*"must be boolean"* ]] && pass "review must be boolean" || fail "unexpected message: $out"
out=$(review review-auto "{\"source\": \"local\", \"review\": true, \"auto_merge\": true, $watch}") && fail "review with auto_merge accepted"
[[ $out == *"cannot also set auto_merge"* ]] && pass "review with auto_merge is refused" || fail "unexpected message: $out"
out=$(review review-nowatch '{"source": "local", "review": true}') && fail "review without a watch accepted"
[[ $out == *"only an upstream watch"* ]] && pass "review without a watch is refused" || fail "unexpected message: $out"

# A five-minute package leaves the hourly group, which would otherwise push the
# same auto/track-branches PR from a second, concurrent run.
mkdir -p "$T/five/.omarchy"
echo "{\"source\": \"local\", \"auto_merge\": true, \"sync_cadence\": \"five-minute\", $watch}" > "$T/five/.omarchy/package.json"
package_in_lane "$T/five" five-minute && ! package_in_lane "$T/five" auto-merge &&
  pass "a five-minute package syncs only in the five-minute group" || fail "a five-minute package is in the hourly group"
out=$(review five-reviewed "{\"source\": \"local\", \"sync_cadence\": \"five-minute\", $watch}") && fail "five-minute without auto_merge accepted"
[[ $out == *"only an auto-merged package"* ]] && pass "five-minute without auto_merge is refused" || fail "unexpected message: $out"

# package_policy_moves_to_channel must match !package_builds_for_mirror (and
# hold pinned packages out of rc) for every (pinned, release_ring, channel) tuple.
for pinned in false true; do
  for ring in "" fast; do
    d="$T/policy-$pinned-${ring:-std}"
    mkdir -p "$d/.omarchy"
    : > "$d/PKGBUILD"
    printf '{"source":"local","pinned":%s%s}\n' "$pinned" "${ring:+,\"release_ring\":\"$ring\"}" > "$d/.omarchy/package.json"
    for ch in rc stable; do
      want=1
      if [[ $ch == rc && $pinned == true ]]; then
        want=1
      elif ! package_builds_for_mirror "$d" "$ch"; then
        want=0
      fi
      got=0; package_policy_moves_to_channel "$pinned" "$ring" "$ch" || got=1
      (( got == want )) || fail "policy drift for pinned=$pinned ring=${ring:-std} ch=$ch (want=$want got=$got)"
    done
  done
done
pass "package_policy_moves_to_channel matches package_builds_for_mirror for every policy tuple"
