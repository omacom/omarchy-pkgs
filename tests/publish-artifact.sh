#!/bin/bash
# Self-test for bin/publish-artifact against a local directory as the remote.
# Needs repo-add, gpg, rclone, bsdtar (run in the Arch builder/test container).
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d)
GPG_TEST_HOME="$T/g"
GPG_STOPPED=0
S3_PID=""
STOP_RC=0
stop_s3() {
  [[ -n $S3_PID ]] || return 0
  if kill "$S3_PID" 2>/dev/null; then
    wait "$S3_PID" 2>/dev/null || true
  fi
  S3_PID=""
}
stop_gpg() {
  (( GPG_STOPPED == 0 )) && [[ -d $GPG_TEST_HOME ]] || return 0
  local rc=0
  GNUPGHOME="$GPG_TEST_HOME" timeout -k 1 5 gpgconf --kill all >/dev/null 2>&1 || rc=1
  GNUPGHOME="$GPG_TEST_HOME" timeout -k 1 5 gpgconf --remove-socketdir >/dev/null 2>&1 || rc=1
  (( rc == 0 )) && GPG_STOPPED=1
  return "$rc"
}
cleanup() {
  local rc=$?
  trap '' INT TERM HUP
  stop_s3
  stop_gpg || true
  if ! rm -rf "$T"; then
    echo "FAIL: failed to remove temporary directory $T" >&2
    (( rc == 0 )) && rc=1
  fi
  exit "$rc"
}
defer_signals() {
  STOP_RC=0
  trap 'STOP_RC=130' INT
  trap 'STOP_RC=143' TERM
  trap 'STOP_RC=129' HUP
}
arm_signals() {
  trap - INT TERM HUP
  (( STOP_RC == 0 )) || exit "$STOP_RC"
}
trap cleanup EXIT

# Isolate HOME/XDG/rclone so neither gpg nor rclone touches the caller's home.
for _v in "${!RCLONE_@}"; do unset "$_v"; done
unset GNUPGHOME OMARCHY_PUBLISH_PREFIX
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" RCLONE_CONFIG="$T/rclone.conf"
mkdir -p "$HOME"
: > "$RCLONE_CONFIG"

REMOTE="$T/r2"; mkdir -p "$REMOTE"

# throwaway signing key
mkdir -m700 "$GPG_TEST_HOME"
gpg_test() { GNUPGHOME="$GPG_TEST_HOME" gpg "$@"; }
gpg_test --batch --quiet --passphrase "" --quick-gen-key 'Test <t@t>' ed25519 sign 0 2>/dev/null
GPG_PRIVATE_KEY=$(gpg_test --batch --armor --export-secret-keys 'Test <t@t>')
export GPG_PRIVATE_KEY GPG_PASSPHRASE=""

# minimal valid Arch package archives via bsdtar + .PKGINFO
mkpkg() { # mkpkg <name> <pkgrel> <arch> [payload]
  local d="$T/src/$1-$2${4:+-$4}" payload="${4:-payload}" out
  out="$d/$1-1.0-$2-$3.pkg.tar.zst"
  mkdir -p "$d/usr/share" || return
  printf '%s\n' "$payload" > "$d/usr/share/$1-$2" || return
  printf 'pkgname = %s\npkgbase = %s\npkgver = 1.0-%s\npkgdesc = test fixture\nbuilddate = 1700000000\npackager = Test <t@t>\nsize = %d\narch = %s\n' \
    "$1" "$1" "$2" "$(( ${#payload} + 1 ))" "$3" > "$d/.PKGINFO" || return
  ( cd "$d" && bsdtar --zstd -cf "$out" .PKGINFO usr ) || return
  printf '%s\n' "$out"
}
A1=$(mkpkg alpha 1 any)
A2=$(mkpkg alpha 2 any)
B1=$(mkpkg beta 1 x86_64)
C1=$(mkpkg gamma 1 aarch64)

pub() { "$ROOT/bin/publish-artifact" --remote "$REMOTE" --mirror edge --arch x86_64 "$@" >"$T/out" 2>&1; }
entries() { tar -tf "$REMOTE/edge/x86_64/omarchy.db.tar.zst" | grep '/$' | sort | tr '\n' ' '; }
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; cat "$T/out"; exit 1; }
flip_last_byte() {
  local f=$1 size byte oct
  size=$(wc -c < "$f")
  (( size > 0 )) || fail "flip_last_byte: empty file $f"
  byte=$(tail -c 1 "$f" | od -An -tu1)
  printf -v oct '%03o' $(( byte ^ 1 ))
  printf '%b' "\0$oct" | dd of="$f" bs=1 seek=$(( size - 1 )) conv=notrunc status=none
}
# An exited agent stays a zombie when the container's PID 1 does not reap
# orphans, and kill -0 succeeds on a zombie.
agent_running() {
  local state
  state=$(awk '$1 == "State:" { print $2; exit }' "/proc/$1/status" 2>/dev/null) || return 1
  [[ -n $state && $state != [ZX] ]]
}

# Fake rclone wrapper that fails `lsf` with a chosen exit code while delegating
# everything else to the real binary.
REAL_RCLONE=$(command -v rclone)
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
cat <<RCLONE_EOF > "$FAKEBIN/rclone"
#!/bin/bash
if [[ -n \${LOG_RCLONE:-} ]]; then
  printf '%s\n' "\$*" >> "\$LOG_RCLONE"
fi
if [[ \${1:-} == lsf && -n \${FAIL_LSF_RC:-} ]]; then
  [[ -n \${FAIL_LSF_STDOUT:-} ]] && printf '%s\n' "\$FAIL_LSF_STDOUT"
  echo "simulated rclone lsf failure (rc=\$FAIL_LSF_RC)" >&2
  exit "\$FAIL_LSF_RC"
fi
if [[ \${1:-} == lsf && -n \${STRIP_LSF_HASH:-} && " \$* " == *"--format shp"* ]]; then
  "$REAL_RCLONE" "\$@" | awk -F';' 'BEGIN{OFS=";"} {\$2=""; print}'
  exit "\${PIPESTATUS[0]}"
fi
if [[ \${1:-} == hashsum && -n \${STRIP_LSF_HASH:-} ]]; then
  printf '%32s  %s\n' '' "\$(basename "\${3:-}")"
  exit 0
fi
if [[ \${1:-} == copy && -n \${INJECT_SRC:-} && " \$* " == *"\${INJECT_MATCH:-}"* ]]; then
  cp "\$INJECT_SRC" "\$INJECT_DST"
fi
if [[ (\${1:-} == copy || \${1:-} == copyto) && -n \${FAIL_COPY_RC:-} && " \$* " == *"\${FAIL_COPY_MATCH:-}"* ]]; then
  echo "simulated rclone \${1} failure (rc=\$FAIL_COPY_RC)" >&2
  exit "\$FAIL_COPY_RC"
fi
exec "$REAL_RCLONE" "\$@"
RCLONE_EOF
chmod +x "$FAKEBIN/rclone"

# Optional pass-through gpg/gpgconf wrappers to verify bin/publish-artifact cleans up its temp GNUPGHOME.
REAL_GPG=$(command -v gpg)
REAL_GPGCONF=$(command -v gpgconf)
REAL_GPG_CONNECT=$(command -v gpg-connect-agent)
cat <<GPG_EOF > "$FAKEBIN/gpg"
#!/bin/bash
if [[ -n \${LOG_GPG_SOCK:-} ]]; then
  rc=0
  "$REAL_GPG" "\$@" || rc=\$?
  agent_pid=\$("$REAL_GPG_CONNECT" --no-autostart 'GETINFO pid' /bye 2>/dev/null | awk '\$1=="D"{print \$2; exit}')
  printf '%s\0%s\0%s\0' "\${GNUPGHOME:-}" "\$("$REAL_GPGCONF" --list-dirs socketdir)" "\$agent_pid" >> "\$LOG_GPG_SOCK"
  exit "\$rc"
fi
exec "$REAL_GPG" "\$@"
GPG_EOF
chmod +x "$FAKEBIN/gpg"
cat <<GPGCONF_EOF > "$FAKEBIN/gpgconf"
#!/bin/bash
if [[ -n \${LOG_GPGCONF:-} ]]; then
  rc=0
  "$REAL_GPGCONF" "\$@" || rc=\$?
  printf '%s %s rc=%d\n' "\${GNUPGHOME:-}" "\$*" "\$rc" >> "\$LOG_GPGCONF"
  exit "\$rc"
fi
exec "$REAL_GPGCONF" "\$@"
GPGCONF_EOF
chmod +x "$FAKEBIN/gpgconf"

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
defer_signals
python3 "$ROOT/tests/fixtures/mock-s3-server.py" "$S3_MODE" "$S3_PORT" >"$T/s3.log" 2>&1 &
S3_PID=$!
arm_signals
for _ in $(seq 1 50); do [[ -s "$S3_PORT" ]] && break; kill -0 "$S3_PID" 2>/dev/null || break; sleep 0.05; done
if [[ ! -s "$S3_PORT" ]]; then
  echo "FAIL: mock S3 server failed to start"
  cat "$T/s3.log"
  exit 1
fi
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
  grep -q 'Failed to list' "$T/out" && grep -q 'InternalError' "$T/out" \
    && pass "S3 500 error fails closed even with --init" || fail "S3 500"
fi
stop_s3

# Valid 0-entry omarchy.db.tar.zst is an initialized empty channel: live publish
# must succeed without --init (GNU tar exits 2 on --wildcards "*/desc" if not guarded).
tar --zstd -cf "$REMOTE/edge/x86_64/omarchy.db.tar.zst" -T /dev/null
tar --zstd -cf "$REMOTE/edge/x86_64/omarchy.files.tar.zst" -T /dev/null
pub "$A1" && [[ "$(entries)" == "alpha-1.0-1/ " ]] \
  && pass "live publish succeeds into a valid empty db without --init" || fail "empty db publish"
rm -f "$REMOTE/edge/x86_64"/*
rmdir "$REMOTE/edge/x86_64"
pub --init "$A1" && [[ "$(entries)" == "alpha-1.0-1/ " ]] && [[ -f "$REMOTE/edge/x86_64/$(basename "$A1").sig" ]] \
  && pass "first publish with --init creates db with one entry and a signature" || fail "first publish"

sum_before=$(sha256sum "$REMOTE/edge/x86_64/$(basename "$A1")")
: > "$T/gpg.sock"
: > "$T/gpgconf.log"
PATH="$FAKEBIN:$PATH" LOG_GPG_SOCK="$T/gpg.sock" LOG_GPGCONF="$T/gpgconf.log" pub "$B1" \
  && [[ "$(entries)" == "alpha-1.0-1/ beta-1.0-1/ " ]] && [[ "$(sha256sum "$REMOTE/edge/x86_64/$(basename "$A1")")" == "$sum_before" ]] \
  && pass "second package added incrementally; first file untouched" || fail "incremental add"
pub_gnupghome="" sockdir="" agent_pid=""
{ IFS= read -r -d '' pub_gnupghome && IFS= read -r -d '' sockdir && IFS= read -r -d '' agent_pid; } < "$T/gpg.sock" || true
if [[ -n $agent_pid ]]; then
  for _ in $(seq 1 20); do agent_running "$agent_pid" || break; sleep 0.05; done
fi
if [[ -z $pub_gnupghome || -z $sockdir || -z $agent_pid || -e $pub_gnupghome || -e $sockdir ]] \
  || agent_running "$agent_pid" \
  || ! grep -qxF "$pub_gnupghome --kill all rc=0" "$T/gpgconf.log" \
  || ! grep -qxF "$pub_gnupghome --remove-socketdir rc=0" "$T/gpgconf.log"; then
  fail "publish-artifact did not clean up temp GNUPGHOME ($pub_gnupghome / $sockdir / pid=$agent_pid): $(cat "$T/gpgconf.log")"
fi
pass "publish-artifact stops gpg-agent and removes its temporary socketdir on exit"

# No .old backup files from repo-add may be uploaded to the remote.
if compgen -G "$REMOTE/edge/x86_64/*.old" >/dev/null; then
  fail "repo-add .old backup files leaked to remote: $(ls "$REMOTE/edge/x86_64"/*.old)"
else
  [[ -f "$REMOTE/edge/x86_64/omarchy.db" && -f "$REMOTE/edge/x86_64/omarchy.files" ]] \
    && pass "incremental publish uploads db/files without .old backups" || fail "missing db/files aliases"
fi

# Missing, corrupt, or failed omarchy.files.tar.zst pull must fail closed instead
# of silently rebuilding omarchy.files with only the incoming package.
db_sum_before=$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")
files_bak="$T/omarchy.files.tar.zst.bak"
cp "$REMOTE/edge/x86_64/omarchy.files.tar.zst" "$files_bak"

rm "$REMOTE/edge/x86_64/omarchy.files.tar.zst"
pub "$A2" && fail "missing omarchy.files.tar.zst should fail closed" || true
cp "$files_bak" "$REMOTE/edge/x86_64/omarchy.files.tar.zst"
grep -q 'Failed to pull omarchy.files.tar.zst' "$T/out" \
  && [[ "$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")" == "$db_sum_before" ]] \
  && pass "missing omarchy.files.tar.zst fails closed" || fail "missing files db reason"

printf 'corrupt archive\n' > "$REMOTE/edge/x86_64/omarchy.files.tar.zst"
pub "$A2" && fail "corrupt omarchy.files.tar.zst should fail closed" || true
cp "$files_bak" "$REMOTE/edge/x86_64/omarchy.files.tar.zst"
[[ "$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")" == "$db_sum_before" ]] \
  && pass "corrupt omarchy.files.tar.zst fails closed" || fail "corrupt files db"

PATH="$FAKEBIN:$PATH" FAIL_COPY_RC=1 FAIL_COPY_MATCH="/omarchy.files.tar.zst" pub "$A2" \
  && fail "rclone copy failure on db/files pull should fail closed" || true
grep -q 'simulated rclone copy failure' "$T/out" \
  && [[ "$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")" == "$db_sum_before" ]] \
  && pass "rclone copy failure on db/files pull fails closed" || fail "files copy failure"

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
  ( cd "$REMOTE/edge/x86_64" && repo-remove --quiet omarchy.db.tar.zst alpha >/dev/null 2>&1 && rm -f ./*.old )
  [[ "$(entries)" == "beta-1.0-1/ " ]] || fail "fixture: could not drop alpha from the db"
}

# Orphan repair: a file that reached the remote but whose db entry was lost
# (a concurrent publish overwrote the db) is fixed by publishing it again, and
# verifies + reuses the immutable remote .sig so %PGPSIG% matches it byte-for-byte.
drop_alpha
a2_sig="$REMOTE/edge/x86_64/$(basename "$A2").sig"
# Replace remote .sig with a distinct valid signature from the same key so
# reusing vs re-signing is observable and deterministic.
gpg_test --batch --yes --pinentry-mode loopback --passphrase "" \
  --set-notation test@omarchy=orig --detach-sign --no-armor -o "$a2_sig" "$A2"
cp "$a2_sig" "$T/a2.sig.orig"
pub "$A2" \
  && grep -q 'identical bytes' "$T/out" && grep -q 'reused existing signature' "$T/out" \
  && [[ "$(entries)" == "alpha-1.0-2/ beta-1.0-1/ " ]] && cmp -s "$a2_sig" "$T/a2.sig.orig" \
  || fail "orphan repair"
pgpsig=$(tar -xO --zstd -f "$REMOTE/edge/x86_64/omarchy.db.tar.zst" alpha-1.0-2/desc \
  | awk '/^%PGPSIG%$/{getline; print; exit}')
[[ -n "$pgpsig" ]] && cmp -s "$a2_sig" <(base64 -d <<<"$pgpsig") \
  && pass "orphaned file regains its db entry with %PGPSIG% matching remote .sig" || fail "orphan %PGPSIG% drift"

# A corrupt/unverifiable remote .sig on an orphan retry must fail closed.
drop_alpha
printf 'not a valid signature\n' > "$a2_sig"
db_sum_before=$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")
pub "$A2" && fail "corrupt remote .sig on orphan retry should fail closed" || true
cp "$T/a2.sig.orig" "$a2_sig"
grep -q 'does not verify' "$T/out" \
  && [[ "$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")" == "$db_sum_before" ]] \
  && pass "corrupt remote .sig on orphan retry fails closed" || fail "corrupt remote sig"

# A same-size sidecar appearing after the initial listing with different bytes
# must fail the checksum check before any metadata upload is attempted.
rm "$a2_sig"
gpg_test --batch --yes --pinentry-mode loopback --passphrase "" \
  --detach-sign --no-armor -o "$T/a2.sig.same-size" "$A2"
flip_last_byte "$T/a2.sig.same-size"
db_sum_before=$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")
: > "$T/rclone.log"
PATH="$FAKEBIN:$PATH" LOG_RCLONE="$T/rclone.log" INJECT_MATCH="*.pkg.tar.*.sig" INJECT_SRC="$T/a2.sig.same-size" INJECT_DST="$a2_sig" pub "$A2" \
  && fail "concurrent sidecar with different bytes should fail closed" || true
grep -q 'Remote checksum mismatch' "$T/out" \
  && ! grep -q '^copyto ' "$T/rclone.log" \
  && [[ "$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")" == "$db_sum_before" ]] \
  && pass "concurrent same-size sidecar mismatch fails checksum before metadata upload" || fail "sidecar mismatch"

# Orphaned package whose .sig never uploaded is signed fresh and uploaded.
rm "$a2_sig"
pub "$A2" && grep -q 'identical bytes' "$T/out" && grep -q 'signed alpha-1.0-2' "$T/out" \
  && [[ -f "$a2_sig" ]] \
  && pass "orphaned package without remote .sig signs and uploads fresh .sig" || fail "orphan missing sig"

# Different bytes under an existing name: refused. Build alpha-2 again with
# a different payload so the archive bytes differ.
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
# A same-size different-byte package appearing after initial listing must fail
# the checksum check before any metadata upload is attempted.
db_sum_before=$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")
cp "$D1" "$T/d1.same-size"
flip_last_byte "$T/d1.same-size"
: > "$T/rclone.log"
PATH="$FAKEBIN:$PATH" LOG_RCLONE="$T/rclone.log" INJECT_MATCH="- *.sig" INJECT_SRC="$T/d1.same-size" INJECT_DST="$REMOTE/edge/x86_64/$(basename "$D1")" pub "$D1" \
  && fail "concurrent package collision should fail closed" || true
rm -f "$REMOTE/edge/x86_64/$(basename "$D1")" "$REMOTE/edge/x86_64/$(basename "$D1").sig"
grep -q 'Remote checksum mismatch' "$T/out" \
  && ! grep -q '^copyto ' "$T/rclone.log" \
  && [[ "$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")" == "$db_sum_before" ]] \
  && pass "concurrent same-size package collision fails checksum before metadata upload" || fail "pkg collision"

# When remote lsf omits MD5 (e.g. S3 multipart upload), streaming fallback still catches mismatch.
: > "$T/rclone.log"
PATH="$FAKEBIN:$PATH" LOG_RCLONE="$T/rclone.log" STRIP_LSF_HASH=1 INJECT_MATCH="- *.sig" INJECT_SRC="$T/d1.same-size" INJECT_DST="$REMOTE/edge/x86_64/$(basename "$D1")" pub "$D1" \
  && fail "empty-hash fallback should still catch package mismatch" || true
rm -f "$REMOTE/edge/x86_64/$(basename "$D1")" "$REMOTE/edge/x86_64/$(basename "$D1").sig"
grep -q 'Remote checksum mismatch' "$T/out" && grep -q '^cat ' "$T/rclone.log" \
  && ! grep -q '^copyto ' "$T/rclone.log" \
  && pass "empty-hash fallback verifies via rclone cat and fails closed on mismatch" || fail "empty-hash fallback"

# Empty-hash fallback also succeeds on orphan retry when remote bytes match.
drop_alpha
: > "$T/rclone.log"
PATH="$FAKEBIN:$PATH" LOG_RCLONE="$T/rclone.log" STRIP_LSF_HASH=1 pub "$A2" \
  && grep -q 'identical bytes' "$T/out" && grep -q '^cat ' "$T/rclone.log" \
  && [[ "$(entries)" == "alpha-1.0-2/ beta-1.0-1/ " ]] \
  && pass "empty-hash fallback succeeds on matching orphan retry" || fail "empty-hash orphan ok"

# Failed unpublish of beta (files landed, db.tar.zst failed) followed by an unrelated
# publish of delta must refuse to commit mismatched db and files indexes.
db_sum_before=$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")
cp "$REMOTE/edge/x86_64/omarchy.files.tar.zst" "$T/files.pre-unpub"
cp "$REMOTE/edge/x86_64/omarchy.files" "$T/files.alias.pre-unpub"
cp "$REMOTE/edge/x86_64/omarchy.db" "$T/db.alias.pre-unpub"
PATH="$FAKEBIN:$PATH" FAIL_COPY_RC=1 FAIL_COPY_MATCH="/omarchy.db.tar.zst --s3-no-head --checksum" \
  "$ROOT/bin/unpublish-packages" --remote "$REMOTE" --mirror edge --arch x86_64 beta >"$T/out" 2>&1 \
  && fail "fixture: simulated partial unpublish should fail" || true
: > "$T/rclone.log"
PATH="$FAKEBIN:$PATH" LOG_RCLONE="$T/rclone.log" pub "$D1" \
  && fail "unrelated publish over diverged db/files should fail closed" || true
cp "$T/files.pre-unpub" "$REMOTE/edge/x86_64/omarchy.files.tar.zst"
cp "$T/files.alias.pre-unpub" "$REMOTE/edge/x86_64/omarchy.files"
cp "$T/db.alias.pre-unpub" "$REMOTE/edge/x86_64/omarchy.db"
rm -f "$REMOTE/edge/x86_64/$(basename "$D1")" "$REMOTE/edge/x86_64/$(basename "$D1").sig"
grep -q 'entries diverge' "$T/out" && ! grep -q '^copyto ' "$T/rclone.log" \
  && [[ ! -e "$REMOTE/edge/x86_64/$(basename "$D1")" ]] \
  && [[ "$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")" == "$db_sum_before" ]] \
  && pass "unrelated publish refuses to commit diverged db/files after partial unpublish" || fail "diverged index publish"

# Simulate mid-upload failure after omarchy.files.tar.zst, omarchy.files, and omarchy.db
# land, failing on omarchy.db.tar.zst (the commit point): retry must succeed and
# leave omarchy.files.tar.zst with exact flat paths (no nested pkg/pkg/ dirs).
PATH="$FAKEBIN:$PATH" FAIL_COPY_RC=1 FAIL_COPY_MATCH="/omarchy.db.tar.zst --s3-no-head --checksum" pub "$A1" "$A3" "$D1" \
  && fail "failed omarchy.db.tar.zst upload should fail closed" || true
[[ "$(sha256sum "$REMOTE/edge/x86_64/omarchy.db.tar.zst")" == "$db_sum_before" ]] \
  || fail "omarchy.db.tar.zst changed despite simulated failure"
[[ "$(tar -tf "$REMOTE/edge/x86_64/omarchy.files.tar.zst" | grep '/$' | sort | tr '\n' ' ')" == "alpha-1.0-3/ beta-1.0-1/ delta-1.0-1/ " ]] \
  || fail "fixture: expected omarchy.files.tar.zst to have landed before db failure"

: > "$T/rclone.log"
PATH="$FAKEBIN:$PATH" LOG_RCLONE="$T/rclone.log" pub "$A1" "$A3" "$D1" \
  && [[ "$(entries)" == "alpha-1.0-3/ beta-1.0-1/ delta-1.0-1/ " ]] \
  && cmp -s "$REMOTE/edge/x86_64/omarchy.db" "$REMOTE/edge/x86_64/omarchy.db.tar.zst" \
  && cmp -s "$REMOTE/edge/x86_64/omarchy.files" "$REMOTE/edge/x86_64/omarchy.files.tar.zst" \
  && [[ "$(tar -tf "$REMOTE/edge/x86_64/omarchy.files.tar.zst" | sort | tr '\n' ' ')" == "alpha-1.0-3/ alpha-1.0-3/desc alpha-1.0-3/files beta-1.0-1/ beta-1.0-1/desc beta-1.0-1/files delta-1.0-1/ delta-1.0-1/desc delta-1.0-1/files " ]] \
  && pass "mixed-generation retry heals cleanly without nested files entries" || fail "mixed publish: $(tar -tf "$REMOTE/edge/x86_64/omarchy.files.tar.zst" | sort | tr '\n' ' ')"

# Upload ordering: pkg -> .sig -> lsf -> files.tar.zst -> files -> db -> db.tar.zst last.
pkg_line=$(grep -Fn -- '--filter - *.sig --filter + *.pkg.tar.*' "$T/rclone.log" | cut -d: -f1 | head -n1)
sig_line=$(grep -Fn -- '--filter + *.pkg.tar.*.sig' "$T/rclone.log" | cut -d: -f1 | head -n1)
lsf_line=$(grep -n '^lsf --format shp ' "$T/rclone.log" | cut -d: -f1 | tail -n1)
ftz_line=$(grep -Fn -- '/omarchy.files.tar.zst --s3-no-head --checksum' "$T/rclone.log" | cut -d: -f1 | tail -n1)
fal_line=$(grep -Fn -- '/omarchy.files --s3-no-head --checksum' "$T/rclone.log" | cut -d: -f1 | tail -n1)
dal_line=$(grep -Fn -- '/omarchy.db --s3-no-head --checksum' "$T/rclone.log" | cut -d: -f1 | tail -n1)
dtz_line=$(grep -Fn -- '/omarchy.db.tar.zst --s3-no-head --checksum' "$T/rclone.log" | cut -d: -f1 | tail -n1)
[[ -n "$pkg_line" && -n "$sig_line" && -n "$lsf_line" && -n "$ftz_line" && -n "$fal_line" && -n "$dal_line" && -n "$dtz_line" ]] \
  && (( pkg_line < sig_line && sig_line < lsf_line && lsf_line < ftz_line && ftz_line < fal_line && fal_line < dal_line && dal_line < dtz_line )) \
  && pass "upload order puts packages, signatures, files, and db alias before db.tar.zst" || fail "upload order: $(cat "$T/rclone.log")"

! compgen -G "$REMOTE/edge/x86_64/*.old" >/dev/null \
  && pass "no .old files left on remote after publish" || fail ".old files present on remote"

# db must verify: each package's signature checks
( cd "$REMOTE/edge/x86_64" && for f in *.pkg.tar.zst; do gpg_test --batch --quiet --verify "$f.sig" "$f" 2>/dev/null || { echo "FAIL: signature $f"; exit 1; }; done )
pass "all signatures verify"

stop_gpg || fail "failed to stop temporary gpg-agent"
if [[ -e "$HOME/.gnupg" ]]; then
  fail "test or publish-artifact created $HOME/.gnupg"
fi
pass "isolated HOME has no .gnupg directory after full test run"
