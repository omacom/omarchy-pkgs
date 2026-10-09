#!/bin/bash
# Every package's .omarchy/package.json passes validate_package_metadata,
# and a fast-ring package that declares rebuild_on is refused: the fast ring
# ships one edge build to every channel, so nothing rebuilds it when a
# dependency moves.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
source "$ROOT/helpers/package-metadata.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

invalid=()
for pkgdir in "$ROOT"/pkgbuilds/*/; do
  out=$(validate_package_metadata "${pkgdir%/}" 2>&1) || invalid+=("$out")
done
(( ${#invalid[@]} == 0 )) && pass "every package's metadata is valid" || fail "$(printf '%s; ' "${invalid[@]}")"

mkdir -p "$T/fast-rebuild/.omarchy"
echo '{"source": "local", "release_ring": "fast", "rebuild_on": ["qt6-base"]}' > "$T/fast-rebuild/.omarchy/package.json"
out=$(validate_package_metadata "$T/fast-rebuild" 2>&1) && fail "fast ring with rebuild_on accepted"
[[ $out == *"cannot be on the fast ring"* ]] && pass "fast ring with rebuild_on is refused" || fail "unexpected message: $out"

mkdir -p "$T/slow-rebuild/.omarchy"
echo '{"source": "local", "rebuild_on": ["qt6-base"]}' > "$T/slow-rebuild/.omarchy/package.json"
validate_package_metadata "$T/slow-rebuild" >/dev/null && pass "rebuild_on off the fast ring is fine" || fail "rebuild_on alone refused"
