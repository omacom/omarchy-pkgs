#!/bin/bash
# Self-test for bin/promote-artifact against a local directory as the remote:
# a scoped aarch64 promotion edge -> rc over an older version, its rollback,
# the refusals, and that no other channel or architecture changes.
# Needs repo-add, gpg, rclone, bsdtar, makepkg, python (the Arch test container).
set -euo pipefail
SRC_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); chmod 755 "$T"; trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$T"' EXIT
REMOTE="$T/r2"; mkdir -p "$REMOTE"

# A checkout whose recipes are fixtures: membership is what promotion obeys.
ROOT="$T/root"; mkdir -p "$ROOT/bin"
cp "$SRC_ROOT/bin/promote-artifact" "$SRC_ROOT/bin/publish-artifact" "$ROOT/bin/"
cp -r "$SRC_ROOT/helpers" "$ROOT/"
recipe() { # recipe <name> <package.json>
  mkdir -p "$ROOT/pkgbuilds/$1/.omarchy"
  printf 'pkgname=%s\npkgver=1.0\npkgrel=1\narch=(x86_64 aarch64)\n' "$1" >"$ROOT/pkgbuilds/$1/PKGBUILD"
  echo "$2" >"$ROOT/pkgbuilds/$1/.omarchy/package.json"
}
recipe kernel '{"source":"local","channels":["edge","rc"]}'
recipe narrow '{"source":"local","channels":["edge"]}'
recipe pair '{"source":"local","channels":["edge","rc","stable"],"pinned":true}'
recipe shared '{"source":"local"}'
recipe dup '{"source":"local"}'

export GNUPGHOME="$T/g"; mkdir -m700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Test <t@t>' ed25519 sign 0 2>/dev/null
GPG_PRIVATE_KEY=$(gpg --batch --armor --export-secret-keys 'Test <t@t>')
export GPG_PRIVATE_KEY GPG_PASSPHRASE=''
unset GNUPGHOME

build() { # build <dir> <arch>: makepkg, as an unprivileged user when root
  if (( EUID == 0 )); then
    id -u fixture >/dev/null 2>&1 || useradd -m fixture
    chmod 755 "$T/src"; chown -R fixture "$1"
    (cd "$1" && runuser -u fixture -- env CARCH="$2" makepkg -f --nodeps --ignorearch >/dev/null 2>&1)
  else
    (cd "$1" && CARCH="$2" makepkg -f --nodeps --ignorearch >/dev/null 2>&1)
  fi
}
mkpkg() { # mkpkg <name> <pkgrel> <arch> [payload]
  local d="$T/src/$1-$2-$3${4:+-$4}"; mkdir -p "$d"
  printf 'pkgname=%s\npkgver=1.0\npkgrel=%s\narch=(%s)\npackage(){ install -Dm644 /dev/null "$pkgdir/usr/share/%s"; echo "%s" >"$pkgdir/usr/share/%s"; }\n' \
    "$1" "$2" "$3" "$1" "${4:-payload}" "$1" >"$d/PKGBUILD"
  build "$d" "$3"; ls "$d"/*.pkg.tar.zst
}
mksplit() { # mksplit <pkgrel>: kernel and kernel-headers from one pkgbase
  local d="$T/src/kernel-$1"; mkdir -p "$d"
  printf 'pkgbase=kernel\npkgname=(kernel kernel-headers)\npkgver=1.0\npkgrel=%s\narch=(aarch64)\npackage_kernel(){ install -Dm644 /dev/null "$pkgdir/usr/share/k%s"; }\npackage_kernel-headers(){ install -Dm644 /dev/null "$pkgdir/usr/share/h%s"; }\n' "$1" "$1" "$1" >"$d/PKGBUILD"
  build "$d" aarch64; ls "$d"/*.pkg.tar.zst
}
publish() { # publish <mirror> <arch> <files...>
  local mirror=$1 arch=$2; shift 2
  "$ROOT/bin/publish-artifact" --remote "$REMOTE" --mirror "$mirror" --arch "$arch" "$@" >/dev/null 2>&1
}

mapfile -t K2 < <(mksplit 2); mapfile -t K1 < <(mksplit 1)
N1=$(mkpkg narrow 1 aarch64); P1=$(mkpkg pair 1 aarch64); S1=$(mkpkg shared 1 any); S2=$(mkpkg shared 2 any)
F1=$(mkpkg fast 1 aarch64); X1=$(mkpkg xone 1 x86_64); D1=$(mkpkg dup 1 aarch64 edge-bytes); D1b=$(mkpkg dup 1 aarch64 rc-bytes)

publish edge aarch64 "${K2[@]}" "$N1" "$P1" "$S1" "$F1" "$D1"
publish rc aarch64 "${K1[@]}" "$F1" "$D1b"
publish stable aarch64 "$F1" "$S2"
publish edge x86_64 "$X1" "$S1"
publish rc x86_64 "$X1" "$S1"

promote() { "$ROOT/bin/promote-artifact" --remote "$REMOTE" "$@" >"$T/out" 2>&1; }
entries() { tar -tf "$REMOTE/$1/omarchy.db.tar.zst" | grep '/$' | sort | tr '\n' ' '; }
db_hashes() { (cd "$REMOTE" && find . -name 'omarchy.*.tar.zst' | sort | xargs sha256sum); }
others() { grep -v " \./rc/aarch64/" <<<"$1"; }
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; cat "$T/out"; exit 1; }

initial=$(db_hashes); rc_initial=$(entries rc/aarch64)
promote --from edge --to rc --arch aarch64 --package kernel shared --dry-run && grep -q 'would publish: kernel-1.0-2-aarch64' "$T/out" \
  && grep -q -- '--reinstate --to rc --arch aarch64 --file kernel-1.0-1-aarch64.pkg.tar.zst kernel-headers-1.0-1-aarch64.pkg.tar.zst' "$T/out" \
  && grep -q -- '--withdraw --to rc --arch aarch64 --package shared' "$T/out" \
  && [[ "$(db_hashes)" == "$initial" ]] && pass "dry run plans the moves and their undo, and changes nothing" || fail "dry run"
digest=$(sed -n 's/.*Set sha256: \([0-9a-f]\{64\}\).*/\1/p' "$T/out")
[[ $digest =~ ^[0-9a-f]{64}$ ]] || fail "the dry run printed no set digest"

for case in "narrow:widen its channels first" "pair:built natively for rc" "dup:holds other bytes under this version"; do
  if promote --from edge --to rc --arch aarch64 --package "${case%%:*}"; then fail "${case%%:*} should be refused"; fi
  grep -q "${case#*:}" "$T/out" && [[ "$(db_hashes)" == "$initial" ]] && pass "${case%%:*}: refused (${case#*:})" || fail "${case%%:*} reason"
done
if promote --from edge --to rc --arch aarch64 --package kernel shared --expect-sha256 "$(printf '0%.0s' {1..64})"; then fail "wrong digest should refuse"; fi
grep -q 'does not hold the expected set' "$T/out" && [[ "$(db_hashes)" == "$initial" ]] && pass "an unexpected set is refused" || fail "digest reason"
if promote --from edge --to rc --arch aarch64 --package 'Bad!name'; then fail "a bad name should refuse"; fi
grep -q 'Not a package name' "$T/out" && pass "package names are checked" || fail "name reason"

promote --from edge --to rc --arch aarch64 --package kernel shared --expect-sha256 "$digest" \
  && [[ "$(entries rc/aarch64)" == "dup-1.0-1/ fast-1.0-1/ kernel-1.0-2/ kernel-headers-1.0-2/ shared-1.0-1/ " ]] \
  && pass "promotes the qualified set over the older kernel" || fail "promote"
for f in "${K2[@]}" "$S1"; do
  cmp -s "$f" "$REMOTE/rc/aarch64/$(basename "$f")" || fail "$(basename "$f") differs from edge's bytes"
done
sums() { tar -xOf "$REMOTE/$1/omarchy.db.tar.zst" "$2/desc" | sed -n '/%SHA256SUM%/{n;p}'; }
for n in kernel-1.0-2 kernel-headers-1.0-2 shared-1.0-1; do
  [[ "$(sums edge/aarch64 "$n")" == "$(sums rc/aarch64 "$n")" ]] || fail "$n: rc/aarch64 does not carry edge's checksum"
done
pass "rc/aarch64 serves edge's bytes under edge's filenames"
[[ "$(others "$(db_hashes)")" == "$(others "$initial")" ]] && pass "every other database is byte-identical (x86_64, edge, stable)" || fail "another database changed"
gpg --batch --quiet --import <<<"$GPG_PRIVATE_KEY" 2>/dev/null || true
( cd "$REMOTE/rc/aarch64" && for f in kernel-*.pkg.tar.zst shared-*.pkg.tar.zst; do gpg --batch --quiet --verify "$f.sig" "$f" 2>/dev/null || exit 1; done ) \
  && pass "promoted files are signed" || fail "signatures"

rc_after=$(sha256sum <"$REMOTE/rc/aarch64/omarchy.db.tar.zst")
promote --from edge --to rc --arch aarch64 --package kernel shared && grep -q 'already serves the set' "$T/out" \
  && [[ "$(sha256sum <"$REMOTE/rc/aarch64/omarchy.db.tar.zst")" == "$rc_after" ]] && pass "the same promotion again is a no-op" || fail "re-run"

if promote --from rc --to stable --arch aarch64 --package shared; then fail "a backwards move should refuse"; fi
grep -q 'newer than rc' "$T/out" && pass "never moves a package backwards" || fail "backwards reason"

promote --withdraw --to rc --arch aarch64 --package shared \
  && promote --reinstate --to rc --arch aarch64 --file "$(basename "${K1[0]}")" "$(basename "${K1[1]}")" \
  && [[ "$(entries rc/aarch64)" == "$rc_initial" ]] && [[ "$(others "$(db_hashes)")" == "$(others "$initial")" ]] \
  && [[ -f "$REMOTE/rc/aarch64/$(basename "${K2[0]}")" ]] \
  && pass "rollback (withdraw the new, reinstate the replaced) restores rc/aarch64's entries; files stay" || fail "rollback"

promote --withdraw --to rc --arch aarch64 --package kernel && [[ "$(entries rc/aarch64)" == "dup-1.0-1/ fast-1.0-1/ " ]] \
  && pass "withdraw by pkgbase drops the split packages" || fail "withdraw by pkgbase"
if promote --reinstate --to rc --arch aarch64 --file never-1.0-1-aarch64.pkg.tar.zst; then fail "reinstating an absent file should refuse"; fi
grep -q 'does not hold never-1.0-1' "$T/out" && pass "reinstate needs the file in the channel" || fail "reinstate reason"

port=$(( 20000 + RANDOM % 20000 ))
(cd "$REMOTE" && exec python -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
for _ in $(seq 50); do curl -fs "http://127.0.0.1:$port/" >/dev/null && break; sleep 0.1; done
promote --remote "http://127.0.0.1:$port" --from edge --to rc --arch aarch64 --package shared --dry-run \
  && grep -q 'would publish: shared-1.0-1-any' "$T/out" && pass "a dry run reads a public URL" || fail "URL dry run"
if promote --remote "http://127.0.0.1:$port" --from edge --to rc --arch aarch64 --package shared; then fail "a URL must be read-only"; fi
if promote --remote "http://127.0.0.1:1" --from edge --to rc --arch aarch64 --package shared --dry-run; then fail "an unreachable remote should stop"; fi
grep -q 'Cannot read' "$T/out" && pass "an unreadable remote stops rather than reading as empty" || fail "unreachable reason"

if "$ROOT/bin/promote-artifact" --remote "$REMOTE" --from edge --to rc --package kernel >"$T/out" 2>&1; then fail "a missing --arch should refuse"; fi
grep -q -- '--arch is required' "$T/out" && pass "--arch is required" || fail "arch reason"
