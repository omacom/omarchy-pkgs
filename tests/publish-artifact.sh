#!/bin/bash
# Self-test for bin/publish-artifact against a local directory as the remote.
# Needs repo-add, gpg, rclone, bsdtar (run in the Arch builder/test container).
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); chmod 755 "$T"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tool/bin"
cp "$ROOT/bin/publish-artifact" "$T/tool/bin/"
cp -r "$ROOT/helpers" "$T/tool/"
ROOT="$T/tool"
for job in alpha beta gamma; do
  mkdir -p "$ROOT/pkgbuilds/$job/.omarchy"
  printf '{}\n' > "$ROOT/pkgbuilds/$job/.omarchy/package.json"
done
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

approve() {
  local job=$1 file=$2 arch=${3:-x86_64}
  mkdir -p "$T/candidate"
  rm -f "$T/candidate/"*.pkg.tar.zst
  cp "$file" "$T/candidate/"
  basename "$file" > "$T/list"
  python3 "$ROOT/helpers/package-scope.py" create --policy-root "$ROOT/pkgbuilds" \
    --package "$job" --arch "$arch" --directory "$T/candidate" --files "$T/list" > "$T/manifest.json"
}
pub() { "$ROOT/bin/publish-artifact" --remote "$REMOTE" --mirror edge --arch x86_64 --manifest "$T/manifest.json" "$@" >"$T/out" 2>&1; }
entries() { tar -tf "$REMOTE/edge/x86_64/omarchy.db.tar.zst" | grep '/$' | sort | tr '\n' ' '; }
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; cat "$T/out"; exit 1; }

approve alpha "$A1"
pub "$A1" && [[ "$(entries)" == "alpha-1.0-1/ " ]] && [[ -f "$REMOTE/edge/x86_64/$(basename "$A1").sig" ]] \
  && pass "first publish creates db with one entry and a signature" || fail "first publish"

sum_before=$(sha256sum "$REMOTE/edge/x86_64/$(basename "$A1")")
approve beta "$B1"
pub "$B1" && [[ "$(entries)" == "alpha-1.0-1/ beta-1.0-1/ " ]] && [[ "$(sha256sum "$REMOTE/edge/x86_64/$(basename "$A1")")" == "$sum_before" ]] \
  && pass "second package added incrementally; first file untouched" || fail "incremental add"

approve alpha "$A2"
pub "$A2" && [[ "$(entries)" == "alpha-1.0-2/ beta-1.0-1/ " ]] && [[ -f "$REMOTE/edge/x86_64/$(basename "$A1")" ]] \
  && pass "new pkgrel replaces the db entry, old file remains on remote" || fail "replace entry"

# Same bytes again: allowed, idempotent (this is how a fast-ring artifact
# reaches rc and stable after edge, and how a re-run recovers).
pub "$A2" && grep -q 'identical bytes' "$T/out" && [[ "$(entries)" == "alpha-1.0-2/ beta-1.0-1/ " ]] \
  && pass "identical bytes under an existing name: accepted, db unchanged" || fail "identical republish"

# Orphan repair: a file that reached the remote but whose db entry was lost
# (a concurrent publish overwrote the db) is fixed by publishing it again.
( cd "$REMOTE/edge/x86_64" && repo-remove --quiet omarchy.db.tar.zst alpha >/dev/null 2>&1 )
[[ "$(entries)" == "beta-1.0-1/ " ]] || fail "fixture: could not drop alpha from the db"
pub "$A2" && [[ "$(entries)" == "alpha-1.0-2/ beta-1.0-1/ " ]] \
  && pass "orphaned file regains its db entry on republish" || fail "orphan repair"

# Different bytes under an existing name: refused. Build alpha-2 again with
# a different payload (makepkg is reproducible, so the content must change).
A2b=$(mkpkg alpha 2 any different-payload)
[[ "$(md5sum < "$A2")" != "$(md5sum < "$A2b")" ]] || { echo "fixture: rebuilt package is byte-identical, cannot test"; exit 1; }
if pub "$A2b"; then fail "unapproved changed bytes should refuse"; else grep -q 'archive changed' "$T/out" && pass "changed bytes cannot reuse approval" || fail "wrong changed-bytes reason"; fi
approve alpha "$A2b"
if pub "$A2b"; then fail "different bytes under same filename should refuse"; else grep -q 'DIFFERENT bytes' "$T/out" && pass "different bytes under an existing name refused" || fail "wrong refusal reason"; fi

approve gamma "$C1" aarch64
if pub "$C1"; then fail "aarch64 package into x86_64 should refuse"; else grep -q 'foreign target arch' "$T/out" && pass "wrong-arch package refused" || fail "wrong-arch reason"; fi

cp "$B1" "$T/renamed-1.0-1-x86_64.pkg.tar.zst"
approve beta "$B1"
if pub "$T/renamed-1.0-1-x86_64.pkg.tar.zst"; then fail "renamed package should refuse"; else pass "renamed package cannot reuse approval"; fi
if pub "$B1" "$A1"; then fail "additional unapproved output should refuse"; else grep -q 'unexpected or missing' "$T/out" && pass "additional output refused" || fail "additional output reason"; fi

# db must verify: pacman can read it and each package's signature checks
export GNUPGHOME="$T/verify-gpg"; mkdir -m700 "$GNUPGHOME"
gpg --batch --quiet --import <<<"$GPG_PRIVATE_KEY" 2>/dev/null
( cd "$REMOTE/edge/x86_64" && for f in *.pkg.tar.zst; do gpg --batch --quiet --verify "$f.sig" "$f" 2>/dev/null || { echo "FAIL: signature $f"; exit 1; }; done ) && pass "all signatures verify"
