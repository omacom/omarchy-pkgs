#!/bin/bash
# Self-test for bin/publish-artifact against a local directory as the remote.
# Needs repo-add, gpg, rclone, bsdtar (run in the Arch builder/test container).
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); chmod 755 "$T"; trap 'rm -rf "$T"' EXIT
REMOTE="$T/r2"; mkdir -p "$REMOTE"

# throwaway signing key
export GNUPGHOME="$T/g"; mkdir -m700 "$GNUPGHOME"
gpg --batch --quiet --passphrase "" --quick-gen-key 'Test <t@t>' ed25519 sign 0 2>/dev/null
export GPG_PRIVATE_KEY=$(gpg --batch --armor --export-secret-keys 'Test <t@t>') GPG_PASSPHRASE=""
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
if (( EUID == 0 )); then
  id -u fixture >/dev/null 2>&1 || useradd -m fixture
  mkdir -p "$T/src"; chmod 755 "$T/src"
fi
mkpkg alpha 1 any >"$T/p-A1" & p1=$!
mkpkg alpha 2 any >"$T/p-A2" & p2=$!
mkpkg beta 1 x86_64 >"$T/p-B1" & p3=$!
mkpkg gamma 1 aarch64 >"$T/p-C1" & p4=$!
for p in "$p1" "$p2" "$p3" "$p4"; do wait "$p"; done
A1=$(<"$T/p-A1"); A2=$(<"$T/p-A2"); B1=$(<"$T/p-B1"); C1=$(<"$T/p-C1")

pub() { "$ROOT/bin/publish-artifact" --remote "$REMOTE" --mirror edge --arch x86_64 "$@" >"$T/out" 2>&1; }
entries() { tar -tf "$REMOTE/edge/x86_64/omarchy.db.tar.zst" | grep '/$' | sort | tr '\n' ' '; }
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; cat "$T/out"; exit 1; }

# Fake rclone wrapper that fails `lsf` with a chosen exit code while delegating
# everything else to the real binary.
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

# Brand-new channel must refuse to initialize without --init (both missing dir
# and existing empty dir).
if pub "$A1"; then fail "missing channel dir without --init should refuse"; else
  grep -q 'Failed to list' "$T/out" && [[ ! -e "$REMOTE/edge/x86_64/omarchy.db.tar.zst" ]] \
    && pass "missing channel directory refused without --init" || fail "missing dir reason"
fi

mkdir -p "$REMOTE/edge/x86_64"
if pub "$A1"; then fail "empty channel without --init should refuse"; else
  grep -q -- '--init' "$T/out" && [[ ! -e "$REMOTE/edge/x86_64/omarchy.db.tar.zst" ]] \
    && pass "empty channel without db refused without --init" || fail "empty channel reason"
fi

# Even with --init, a non-3 rclone lsf error (5xx/auth/network) must fail closed.
if PATH="$FAKEBIN:$PATH" FAIL_LSF_RC=5 pub --init "$A1"; then
  fail "rclone lsf failure should refuse even with --init"
else
  grep -q 'Failed to list' "$T/out" && grep -q 'simulated rclone lsf failure' "$T/out" \
    && [[ ! -e "$REMOTE/edge/x86_64/omarchy.db.tar.zst" ]] \
    && pass "rclone lsf error fails closed even with --init" || fail "lsf error with --init"
fi

# Partial database artifacts (e.g. surviving omarchy.db without omarchy.db.tar.zst)
# must be refused even with --init so a live index is never wiped.
touch "$REMOTE/edge/x86_64/omarchy.db"
if pub --init "$A1"; then
  fail "partial db artifacts should refuse even with --init"
else
  grep -q 'partial database artifacts' "$T/out" && [[ ! -e "$REMOTE/edge/x86_64/omarchy.db.tar.zst" ]] \
    && pass "--init refuses when partial database artifacts exist" || fail "partial db artifacts"
fi
rm "$REMOTE/edge/x86_64/omarchy.db"

# Real rclone S3/R2 backend behavior via a minimal local mock S3 server:
#   - 200 empty prefix: refused without --init
#   - 404 NoSuchBucket (rclone exit 3): refused EVEN with --init
#   - 500 InternalError (non-zero rclone exit): refused EVEN with --init
S3_MODE="$T/s3-mode"; echo empty > "$S3_MODE"
S3_PORT="$T/s3-port"
python3 - "$S3_MODE" "$S3_PORT" <<'S3_PY' &
import http.server, sys
mode_path, port_path = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        m = open(mode_path).read().strip()
        if m == "empty":
            body = b'<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>omarchy-pkgs</Name><Prefix>edge/x86_64/</Prefix><KeyCount>0</KeyCount><MaxKeys>1000</MaxKeys><IsTruncated>false</IsTruncated></ListBucketResult>'
            self.send_response(200)
        elif m == "404":
            body = b"<Error><Code>NoSuchBucket</Code><Message>No such bucket</Message></Error>"
            self.send_response(404)
        else:
            body = b"<Error><Code>InternalError</Code><Message>Internal Error</Message></Error>"
            self.send_response(500)
        self.send_header("Content-Type", "application/xml")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(port_path, "w").write(str(srv.server_address[1]))
srv.serve_forever()
S3_PY
S3_PID=$!
trap 'kill "$S3_PID" 2>/dev/null || true; rm -rf "$T"' EXIT
for _ in $(seq 1 50); do [[ -s "$S3_PORT" ]] && break; sleep 0.05; done
[[ -s "$S3_PORT" ]] || fail "mock S3 server failed to start"
s3_pub() {
  RCLONE_CONFIG_S3T_TYPE=s3 RCLONE_CONFIG_S3T_PROVIDER=Cloudflare \
  RCLONE_CONFIG_S3T_NO_CHECK_BUCKET=true RCLONE_CONFIG_S3T_ENDPOINT="http://127.0.0.1:$(<"$S3_PORT")" \
  RCLONE_CONFIG_S3T_ACCESS_KEY_ID=t RCLONE_CONFIG_S3T_SECRET_ACCESS_KEY=t \
  RCLONE_RETRIES=1 RCLONE_LOW_LEVEL_RETRIES=1 \
    "$ROOT/bin/publish-artifact" --remote S3T:omarchy-pkgs --mirror edge --arch x86_64 "$@" >"$T/out" 2>&1
}
echo empty > "$S3_MODE"
if s3_pub "$A1"; then fail "S3 empty prefix without --init should refuse"; else
  grep -q -- '--init' "$T/out" && pass "S3 empty prefix refused without --init" || fail "S3 empty prefix"
fi
echo 404 > "$S3_MODE"
if s3_pub --init "$A1"; then fail "S3 NoSuchBucket (exit 3) should refuse even with --init"; else
  grep -q 'Failed to list' "$T/out" && grep -q 'rclone exited 3' "$T/out" \
    && pass "S3 NoSuchBucket (exit 3) fails closed even with --init" || fail "S3 404"
fi
echo 500 > "$S3_MODE"
if s3_pub --init "$A1"; then fail "S3 500 error should refuse even with --init"; else
  grep -q 'Failed to list' "$T/out" \
    && pass "S3 500 error fails closed even with --init" || fail "S3 500"
fi
kill "$S3_PID" 2>/dev/null || true

# Valid 0-entry omarchy.db.tar.zst is an initialized empty channel: live publish
# must succeed without --init (GNU tar exits 2 on --wildcards "*/desc" if not guarded).
tar --zstd -cf "$REMOTE/edge/x86_64/omarchy.db.tar.zst" -T /dev/null
pub "$A1" && [[ "$(entries)" == "alpha-1.0-1/ " ]] \
  && pass "live publish succeeds into a valid empty db without --init" || fail "empty db publish"
rm -f "$REMOTE/edge/x86_64"/*
rmdir "$REMOTE/edge/x86_64"
pub --init "$A1" && [[ "$(entries)" == "alpha-1.0-1/ " ]] && [[ -f "$REMOTE/edge/x86_64/$(basename "$A1").sig" ]] \
  && pass "first publish with --init creates db with one entry and a signature" || fail "first publish"

sum_before=$(sha256sum "$REMOTE/edge/x86_64/$(basename "$A1")")
pub "$B1" && [[ "$(entries)" == "alpha-1.0-1/ beta-1.0-1/ " ]] && [[ "$(sha256sum "$REMOTE/edge/x86_64/$(basename "$A1")")" == "$sum_before" ]] \
  && pass "second package added incrementally; first file untouched" || fail "incremental add"

# Transient rclone lsf error on a populated channel must fail closed and leave
# the existing database intact (both with and without --init).
db_sum_before=$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")
if PATH="$FAKEBIN:$PATH" FAIL_LSF_RC=1 pub "$A2"; then
  fail "rclone lsf error on live channel should fail closed"
else
  grep -q 'Failed to list' "$T/out" && grep -q 'simulated rclone lsf failure' "$T/out" \
    && [[ "$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")" == "$db_sum_before" ]] \
    && [[ "$(entries)" == "alpha-1.0-1/ beta-1.0-1/ " ]] \
    && pass "rclone lsf error fails closed and preserves live db" || fail "live db lsf error"
fi
if PATH="$FAKEBIN:$PATH" FAIL_LSF_RC=5 pub --init "$A2"; then
  fail "rclone lsf error with --init on live channel should fail closed"
else
  grep -q 'Failed to list' "$T/out" \
    && [[ "$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")" == "$db_sum_before" ]] \
    && [[ "$(entries)" == "alpha-1.0-1/ beta-1.0-1/ " ]] \
    && pass "rclone lsf error with --init preserves live db" || fail "live db lsf error with --init"
fi
if PATH="$FAKEBIN:$PATH" FAIL_LSF_RC=1 FAIL_LSF_STDOUT=omarchy.db.tar.zst pub "$A2"; then
  fail "failed rclone lsf that already emitted db name should still fail closed"
else
  grep -q 'Failed to list' "$T/out" \
    && [[ "$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")" == "$db_sum_before" ]] \
    && pass "failed rclone lsf emitting db name before error still fails closed" || fail "partial stdout lsf error"
fi

pub "$A2" && [[ "$(entries)" == "alpha-1.0-2/ beta-1.0-1/ " ]] && [[ -f "$REMOTE/edge/x86_64/$(basename "$A1")" ]] \
  && pass "new pkgrel replaces the db entry, old file remains on remote" || fail "replace entry"

# Passing --init on a channel that already has a database preserves existing entries.
A2_check_entries=$(entries)
pub --init "$A2" && grep -q 'nothing published' "$T/out" && [[ "$(entries)" == "$A2_check_entries" ]] \
  && pass "--init on existing channel reads existing db instead of wiping it" || fail "--init on existing db"

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
