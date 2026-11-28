#!/bin/bash
# Self-test for bin/refresh-pgp-keys: --check mode, path scoping, cross-copy
# drift detection, in-place refresh, and revocation exit code. Runs offline
# against temporary generated keys so it never touches the network.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d)
cleanup() {
  for d in "$T"/gpg-*; do
    [[ -d $d ]] || continue
    GNUPGHOME="$d" timeout 5 gpgconf --kill all 2>/dev/null || true
  done
  rm -rf "$T"
}
trap cleanup EXIT

pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  [[ -f $T/out ]] && cat "$T/out"
  exit 1
}

# Generate a primary key (key1) and export an initial trimmed copy before
# adding a signing subkey, plus a revocation certificate for the revocation test.
mkdir -p "$T/gpg-1" "$T/gpg-2"
chmod 700 "$T/gpg-1" "$T/gpg-2"

GNUPGHOME="$T/gpg-1" gpg --batch --passphrase '' --quick-generate-key "Test One <one@example.invalid>" default default never >/dev/null 2>&1
fpr1=$(GNUPGHOME="$T/gpg-1" gpg --with-colons --list-keys | awk -F: '$1 == "fpr" { print $10; exit }')
GNUPGHOME="$T/gpg-1" gpg --batch --armor --export-options export-clean --export "$fpr1" >"$T/key1-old.asc"

GNUPGHOME="$T/gpg-1" gpg --batch --passphrase '' --quick-add-key "$fpr1" default sign never >/dev/null 2>&1
GNUPGHOME="$T/gpg-1" gpg --batch --armor --export-options export-clean --export "$fpr1" >"$T/key1-new.asc"

# gpg creates a ready-to-use revocation certificate in openpgp-revocs.d/
# (with a leading ':' before -----BEGIN to prevent accidental import).
sed 's/^://' "$T/gpg-1/openpgp-revocs.d/$fpr1.rev" | GNUPGHOME="$T/gpg-1" gpg --batch --import >/dev/null 2>&1
GNUPGHOME="$T/gpg-1" gpg --batch --armor --export-options export-clean --export "$fpr1" >"$T/key1-revoked.asc"

GNUPGHOME="$T/gpg-2" gpg --batch --passphrase '' --quick-generate-key "Test Two <two@example.invalid>" default default never >/dev/null 2>&1
fpr2=$(GNUPGHOME="$T/gpg-2" gpg --with-colons --list-keys | awk -F: '$1 == "fpr" { print $10; exit }')
GNUPGHOME="$T/gpg-2" gpg --batch --armor --export-options export-clean --export "$fpr2" >"$T/key2.asc"

# Fake repository layout.
REPO="$T/repo"
mkdir -p "$REPO/pkgbuilds/a/keys/pgp" "$REPO/pkgbuilds/b/keys/pgp" "$REPO/pkgbuilds/c/keys/pgp"
cp "$T/key1-new.asc" "$REPO/pkgbuilds/a/keys/pgp/$fpr1.asc"
cp "$T/key1-new.asc" "$REPO/pkgbuilds/b/keys/pgp/$fpr1.asc"
cp "$T/key2.asc" "$REPO/pkgbuilds/c/keys/pgp/$fpr2.asc"

run_refresh() {
  REFRESH_ROOT="$REPO" REFRESH_OFFLINE=1 "$BASH" "$ROOT/bin/refresh-pgp-keys" "$@" >"$T/out" 2>&1
}

# 1. Up-to-date key passes --check.
run_refresh --check "pkgbuilds/a/keys/pgp/$fpr1.asc" || fail "up-to-date key should pass --check"
grep -q "^current  $fpr1 " "$T/out" || fail "expected current output for $fpr1"
pass "accepts an up-to-date key in --check mode"

# 2. Trimmed/stale copy fails --check without mutating the file.
cp "$T/key1-old.asc" "$REPO/pkgbuilds/a/keys/pgp/$fpr1.asc"
before=$(cat "$REPO/pkgbuilds/a/keys/pgp/$fpr1.asc")
status=0
run_refresh --check "pkgbuilds/a/keys/pgp/$fpr1.asc" || status=$?
((status == 1)) || fail "stale copy should exit 1 (got $status)"
grep -q "^OUTDATED  $fpr1 " "$T/out" || fail "expected OUTDATED output"
[[ $(cat "$REPO/pkgbuilds/a/keys/pgp/$fpr1.asc") == "$before" ]] || fail "--check must not modify files"
pass "rejects a stale copy in --check mode without modifying files"

# 3. Scoping to an unrelated clean key ignores the stale key elsewhere.
run_refresh --check "pkgbuilds/c/keys/pgp/$fpr2.asc" || fail "scoped --check on clean key should exit 0"
grep -q "^current  $fpr2 " "$T/out" || fail "expected current output for $fpr2"
! grep -q "$fpr1" "$T/out" || fail "scoped --check should not inspect unrelated key $fpr1"
pass "scopes --check to the named key files"

# 4. Write mode updates the stale copy so a subsequent --check passes.
status=0
run_refresh "pkgbuilds/a/keys/pgp/$fpr1.asc" || status=$?
((status == 1)) || fail "write mode should exit 1 when updating (got $status)"
grep -q "^UPDATED  $fpr1 " "$T/out" || fail "expected UPDATED output"
run_refresh --check "pkgbuilds/a/keys/pgp/$fpr1.asc" || fail "--check should pass after refresh"
pass "repairs drift in write mode and passes subsequent --check"

# 5. Revoked primary key exits 2.
cp "$T/key1-revoked.asc" "$REPO/pkgbuilds/b/keys/pgp/$fpr1.asc"
status=0
run_refresh --check "pkgbuilds/a/keys/pgp/$fpr1.asc" || status=$?
((status == 2)) || fail "revoked key should exit 2 (got $status)"
grep -q "^REVOKED  $fpr1:" "$T/out" || fail "expected REVOKED output"
pass "exits 2 when a key is revoked"

# 6. Unknown target fails with MISSING (exit 1) and unknown flag exits 64.
status=0
run_refresh --check "pkgbuilds/none/keys/pgp/0000000000000000000000000000000000000000.asc" || status=$?
((status == 1)) || fail "missing target should exit 1 (got $status)"
grep -q "^MISSING  0000000000000000000000000000000000000000:" "$T/out" || fail "expected MISSING output"
status=0
run_refresh --bogus-flag || status=$?
((status == 64)) || fail "unknown flag should exit 64 (got $status)"
pass "rejects missing targets (exit 1) and unknown flags (exit 64)"
