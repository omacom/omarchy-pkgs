#!/bin/bash
# Self-test for bin/publish-artifact against a local directory as the remote.
# Needs repo-add, gpg, rclone, bsdtar (run in the Arch builder/test container).
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); chmod 755 "$T"; trap 'rm -rf "$T"' EXIT
REMOTE="$T/r2"; mkdir -p "$REMOTE"

# throwaway signing key
export GNUPGHOME="$T/g"; mkdir -m700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Test <t@t>' ed25519 sign 0 2>/dev/null
export GPG_PRIVATE_KEY=$(gpg --batch --armor --export-secret-keys 'Test <t@t>') GPG_PASSPHRASE=''
unset GNUPGHOME

# minimal real packages via makepkg
mkpkg() { # mkpkg <name> <pkgrel> <arch> [payload]
  local d="$T/src/$1-$2${4:+-$4}"; mkdir -p "$d"; cd "$d"
  printf 'pkgname=%s\npkgver=1.0\npkgrel=%s\narch=(%s)\npackage(){ install -Dm644 /dev/null "$pkgdir/usr/share/%s-%s"; echo "%s" > "$pkgdir/usr/share/%s-%s"; }\n' "$1" "$2" "$3" "$1" "$2" "${4:-payload}" "$1" "$2" > PKGBUILD
  # CARCH so the PKGINFO records the requested arch (--ignorearch would
  # stamp the host's).
  # makepkg refuses to run as root (the CI test container does); build the
  # fixture as an unprivileged user in that case.
  if (( EUID == 0 )); then
    id -u fixture >/dev/null 2>&1 || useradd -m fixture
    chmod 755 "$T/src"; chown -R fixture "$d"
    runuser -u fixture -- env CARCH=$3 makepkg -f --nodeps --ignorearch >/dev/null 2>&1
  else
    CARCH=$3 makepkg -f --nodeps --ignorearch >/dev/null 2>&1
  fi
  ls "$d"/*.pkg.tar.zst
}
A1=$(mkpkg alpha 1 any); A2=$(mkpkg alpha 2 any); B1=$(mkpkg beta 1 x86_64); C1=$(mkpkg gamma 1 aarch64)

pub() { "$ROOT/bin/publish-artifact" --remote "$REMOTE" --mirror edge --arch x86_64 "$@" >"$T/out" 2>&1; }
entries() { tar -tf "$REMOTE/edge/x86_64/omarchy.db.tar.zst" | grep '/$' | sort | tr '\n' ' '; }
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; cat "$T/out"; exit 1; }

pub "$A1" && [[ "$(entries)" == "alpha-1.0-1/ " ]] && [[ -f "$REMOTE/edge/x86_64/$(basename "$A1").sig" ]] \
  && pass "first publish creates db with one entry and a signature" || fail "first publish"

sum_before=$(sha256sum "$REMOTE/edge/x86_64/$(basename "$A1")")
pub "$B1" && [[ "$(entries)" == "alpha-1.0-1/ beta-1.0-1/ " ]] && [[ "$(sha256sum "$REMOTE/edge/x86_64/$(basename "$A1")")" == "$sum_before" ]] \
  && pass "second package added incrementally; first file untouched" || fail "incremental add"

pub "$A2" && [[ "$(entries)" == "alpha-1.0-2/ beta-1.0-1/ " ]] && [[ -f "$REMOTE/edge/x86_64/$(basename "$A1")" ]] \
  && pass "new pkgrel replaces the db entry, old file remains on remote" || fail "replace entry"

# A channel only moves forward: the version it serves, or an older one, is
# never published again. A re-run of a slot that landed publishes nothing.
pub "$A2" && grep -q 'nothing published' "$T/out" && [[ "$(entries)" == "alpha-1.0-2/ beta-1.0-1/ " ]] \
  && pass "the version the channel serves is not published again" || fail "same version republished"
pub "$A1" && grep -q 'already serves alpha 1.0-2' "$T/out" && [[ "$(entries)" == "alpha-1.0-2/ beta-1.0-1/ " ]] \
  && pass "an older version never takes the channel backwards" || fail "older version published"

drop_alpha() {
  ( cd "$REMOTE/edge/x86_64" && repo-remove --quiet omarchy.db.tar.zst alpha >/dev/null 2>&1 )
  [[ "$(entries)" == "beta-1.0-1/ " ]] || fail "fixture: could not drop alpha from the db"
}

# Orphan repair: a file that reached the remote but whose db entry was lost
# (a concurrent publish overwrote the db) is fixed by publishing it again.
drop_alpha
pub "$A2" && grep -q 'identical bytes' "$T/out" && [[ "$(entries)" == "alpha-1.0-2/ beta-1.0-1/ " ]] \
  && pass "orphaned file regains its db entry on republish" || fail "orphan repair"

# Different bytes under an existing name: refused. Build alpha-2 again with
# a different payload (makepkg is reproducible, so the content must change).
A2b=$(mkpkg alpha 2 any different-payload)
[[ "$(md5sum < "$A2")" != "$(md5sum < "$A2b")" ]] || { echo "fixture: rebuilt package is byte-identical, cannot test"; exit 1; }
sum_before=$(sha256sum < "$REMOTE/edge/x86_64/$(basename "$A2")")
pub "$A2b" && grep -q 'nothing published' "$T/out" && [[ "$(sha256sum < "$REMOTE/edge/x86_64/$(basename "$A2")")" == "$sum_before" ]] \
  && pass "a rebuild of the served version is skipped, the published file untouched" || fail "served version rebuilt"
drop_alpha
if pub "$A2b"; then fail "different bytes under same filename should refuse"; else grep -q 'DIFFERENT bytes' "$T/out" && pass "different bytes under an existing name refused" || fail "wrong refusal reason"; fi
pub "$A2" || fail "fixture: could not restore alpha"

if pub "$C1"; then fail "aarch64 package into x86_64 should refuse"; else grep -q 'publishing to x86_64' "$T/out" && pass "wrong-arch package refused" || fail "wrong-arch reason"; fi

cp "$B1" "$T/renamed-1.0-1-x86_64.pkg.tar.zst"
if pub "$T/renamed-1.0-1-x86_64.pkg.tar.zst"; then fail "filename/PKGINFO mismatch should refuse"; else grep -q 'does not match PKGINFO' "$T/out" && pass "filename must match PKGINFO" || fail "mismatch reason"; fi

A3=$(mkpkg alpha 3 any); D1=$(mkpkg delta 1 any)
pub "$A1" "$A3" "$D1" && [[ "$(entries)" == "alpha-1.0-3/ beta-1.0-1/ delta-1.0-1/ " ]] \
  && pass "newer and new packages publish, the rest are dropped" || fail "mixed publish"

# db must verify: pacman can read it and each package's signature checks
gpg --batch --quiet --import <<<"$GPG_PRIVATE_KEY" 2>/dev/null || true
( cd "$REMOTE/edge/x86_64" && for f in *.pkg.tar.zst; do gpg --batch --quiet --verify "$f.sig" "$f" 2>/dev/null || { echo "FAIL: signature $f"; exit 1; }; done ) && pass "all signatures verify"
