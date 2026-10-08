#!/bin/bash
# The host refuses to sync or advance an architecture CI publishes straight to
# the remote (CI_ONLY_ARCHES): its tree does not hold those files, and a
# database rebuilt from it could drop or downgrade them. Dry runs and other
# architectures are unaffected; OMARCHY_ALLOW_HOST_PUBLISH lifts the guard.
set -euo pipefail
SRC_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/pkgbuilds"
cp "$SRC_ROOT/bin/sync-repo" "$SRC_ROOT/bin/advance-channel" "$T/bin/"
cp -r "$SRC_ROOT/helpers" "$T/"
export OMARCHY_REPO_ROOT="$T/tree" OMARCHY_STATE_DIR="$T/state"
unset OMARCHY_ALLOW_HOST_PUBLISH OMARCHY_CI_ONLY_ARCHES OMARCHY_ARCHES
mkdir -p "$T/tree" "$T/state"

run() { "$@" >"$T/out" 2>&1 </dev/null; }
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; cat "$T/out"; exit 1; }
refused() { grep -q 'Refusing to .* aarch64 from this host' "$T/out"; }

if run "$T/bin/sync-repo" --mirror rc --arch aarch64 --skip-prod-check; then fail "aarch64 sync should refuse"; fi
refused && pass "sync of an aarch64 channel is refused" || fail "sync reason"

if run "$T/bin/sync-repo" --mirror rc --arch x86_64 --skip-prod-check; then fail "fixture: x86_64 sync has no tree"; fi
! refused && grep -q 'Local repository directory not found' "$T/out" && pass "x86_64 sync is not affected" || fail "x86_64 sync"

if OMARCHY_ALLOW_HOST_PUBLISH=1 run "$T/bin/sync-repo" --mirror rc --arch aarch64 --skip-prod-check; then fail "fixture: no tree"; fi
! refused && grep -q 'Local repository directory not found' "$T/out" && pass "OMARCHY_ALLOW_HOST_PUBLISH lifts the guard" || fail "override"

if run "$T/bin/advance-channel" --from edge --to rc --arch aarch64; then fail "aarch64 advance should refuse"; fi
refused && [[ ! -e "$T/tree/rc" ]] && pass "advance into an aarch64 channel is refused before touching the tree" || fail "advance reason"

if run "$T/bin/advance-channel" --from edge --to rc --arch aarch64 --dry-run; then fail "fixture: no source database"; fi
! refused && grep -q 'Source database not found' "$T/out" && pass "a dry run is still allowed" || fail "dry run"

if OMARCHY_ARCHES="x86_64 aarch64" run "$T/bin/advance-channel" --from edge --to rc --arch all; then fail "--arch all with aarch64 should refuse"; fi
refused && ! grep -q 'Source database not found' "$T/out" && pass "--arch all refuses before moving any architecture" || fail "--arch all"
