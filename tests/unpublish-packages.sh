#!/bin/bash
# Self-test for bin/unpublish-packages against a local directory as the remote.
# Needs repo-add, repo-remove, gpg, rclone, bsdtar (run in the Arch test container).
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); chmod 755 "$T"; trap 'rm -rf "$T"' EXIT
REMOTE="$T/r2"; mkdir -p "$REMOTE"

# throwaway signing key (for bootstrapping via publish-artifact)
export GNUPGHOME="$T/g"; mkdir -m700 "$GNUPGHOME"
gpg --batch --quiet --passphrase "" --quick-gen-key 'Test <t@t>' ed25519 sign 0 2>/dev/null
export GPG_PRIVATE_KEY=$(gpg --batch --armor --export-secret-keys 'Test <t@t>') GPG_PASSPHRASE=""
unset GNUPGHOME

mkpkg() { # mkpkg <base> [second pkgname]
  local d="$T/src/$1"; mkdir -p "$d"; cd "$d"
  {
    if [[ -n ${2:-} ]]; then
      printf 'pkgbase=%s\npkgname=(%s %s)\n' "$1" "$1" "$2"
      printf 'package_%s(){ install -Dm644 /dev/null "$pkgdir/usr/share/%s"; }\n' "$1" "$1"
      printf 'package_%s(){ install -Dm644 /dev/null "$pkgdir/usr/share/%s"; }\n' "$2" "$2"
    else
      printf 'pkgname=%s\npackage(){ install -Dm644 /dev/null "$pkgdir/usr/share/%s"; }\n' "$1" "$1"
    fi
    printf 'pkgver=1.0\npkgrel=1\narch=(x86_64)\n'
  } > PKGBUILD
  if (( EUID == 0 )); then
    id -u fixture >/dev/null 2>&1 || useradd -m fixture
    chmod 755 "$T/src"; chown -R fixture "$d"
    runuser -u fixture -- env CARCH=x86_64 PKGEXT=.pkg.tar.zst makepkg -f --nodeps --ignorearch >/dev/null 2>&1
  else
    CARCH=x86_64 PKGEXT=.pkg.tar.zst makepkg -f --nodeps --ignorearch >/dev/null 2>&1
  fi
  ls "$d"/*.pkg.tar.zst
}
if (( EUID == 0 )); then
  id -u fixture >/dev/null 2>&1 || useradd -m fixture
  mkdir -p "$T/src"; chmod 755 "$T/src"
fi
mkpkg alpha >/dev/null & p1=$!
mkpkg beta >/dev/null & p2=$!
mkpkg split split-extra >/dev/null & p3=$!
for p in "$p1" "$p2" "$p3"; do wait "$p"; done

unpub() { "$ROOT/bin/unpublish-packages" --remote "$REMOTE" --mirror edge --arch x86_64 "$@" >"$T/out" 2>&1; }
entries() { tar -tf "$REMOTE/edge/x86_64/omarchy.db.tar.zst" | grep '/$' | tr -d / | sort | tr '\n' ' '; }
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; cat "$T/out"; exit 1; }

REAL_RCLONE=$(command -v rclone)
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
cat <<RCLONE_EOF > "$FAKEBIN/rclone"
#!/bin/bash
if [[ \${1:-} == lsf && -n \${FAIL_LSF_RC:-} ]]; then
  [[ -n \${FAIL_LSF_STDOUT:-} ]] && printf '%s\n' "\$FAIL_LSF_STDOUT"
  echo "simulated rclone lsf failure (rc=\$FAIL_LSF_RC)" >&2
  exit "\$FAIL_LSF_RC"
fi
exec "$REAL_RCLONE" "\$@"
RCLONE_EOF
chmod +x "$FAKEBIN/rclone"

# Missing channel directory (rclone lsf rc=3) fails closed.
if unpub alpha; then
  fail "missing directory should fail closed"
else
  grep -q 'Failed to list' "$T/out" && pass "missing channel directory fails closed" || fail "missing dir reason"
fi

# Existing empty channel directory (rclone lsf rc=0, no db) is a clean no-op.
mkdir -p "$REMOTE/edge/x86_64"
unpub alpha && grep -q 'nothing to remove' "$T/out" \
  && pass "existing empty channel with no db is a no-op" || fail "empty channel no-op"

# Partial database artifact (omarchy.db without omarchy.db.tar.zst) fails closed.
touch "$REMOTE/edge/x86_64/omarchy.db"
if unpub alpha; then
  fail "partial db artifacts should fail closed"
else
  grep -q 'partial database artifacts' "$T/out" \
    && pass "unpublish fails closed when partial database artifacts exist" || fail "unpub partial db"
fi
rm "$REMOTE/edge/x86_64/omarchy.db"

# Bootstrap channel with alpha, beta, and split/split-extra.
"$ROOT/bin/publish-artifact" --init --remote "$REMOTE" --mirror edge --arch x86_64 \
  "$T/src/alpha"/*.pkg.tar.zst "$T/src/beta"/*.pkg.tar.zst "$T/src/split"/*.pkg.tar.zst >"$T/out" 2>&1 \
  || fail "bootstrap publish"

# Transient rclone lsf error (rc=1 / rc=5) fails closed and leaves db intact.
db_sum_before=$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")
for rc in 1 5; do
  if PATH="$FAKEBIN:$PATH" FAIL_LSF_RC=$rc unpub alpha; then
    fail "rclone lsf rc=$rc should fail closed"
  else
    grep -q 'Failed to list' "$T/out" && grep -q 'simulated rclone lsf failure' "$T/out" \
      && [[ "$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")" == "$db_sum_before" ]] \
      && pass "rclone lsf rc=$rc fails closed and preserves db" || fail "lsf rc=$rc"
  fi
done
if PATH="$FAKEBIN:$PATH" FAIL_LSF_RC=1 FAIL_LSF_STDOUT=omarchy.db.tar.zst unpub alpha; then
  fail "failed rclone lsf emitting db name should fail closed"
else
  grep -q 'Failed to list' "$T/out" \
    && [[ "$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")" == "$db_sum_before" ]] \
    && pass "unpublish fails closed when rclone lsf emits db name before failing" || fail "unpub partial stdout"
fi

# Unpublishing a split pkgbase removes all split outputs and keeps the rest.
unpub split && [[ "$(entries)" == "alpha-1.0-1 beta-1.0-1 " ]] \
  && pass "unpublishing a pkgbase removes its split packages and keeps others" || fail "split unpublish: $(entries)"

# Re-running for an already-absent package is a clean no-op.
unpub split && grep -q 'nothing to remove' "$T/out" && [[ "$(entries)" == "alpha-1.0-1 beta-1.0-1 " ]] \
  && pass "unpublishing an absent package is a no-op" || fail "absent package"
