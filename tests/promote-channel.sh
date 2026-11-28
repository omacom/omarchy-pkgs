#!/bin/bash
# Self-test for bin/promote-channel against a local directory as the remote.
# Needs repo-add, gpg, rclone, bsdtar, vercmp (run in the Arch test container).
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); chmod 755 "$T"; trap 'rm -rf "$T"' EXIT
REMOTE="$T/r2"; mkdir -p "$REMOTE"

# throwaway signing key
export GNUPGHOME="$T/g"; mkdir -m700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Test <t@t>' ed25519 sign 0 2>/dev/null
export GPG_PRIVATE_KEY=$(gpg --batch --armor --export-secret-keys 'Test <t@t>') GPG_PASSPHRASE=''
unset GNUPGHOME

# The tooling reads recipes from its own checkout (helpers/paths.sh), so run
# a copy of it whose pkgbuilds/ holds the fixtures.
BIN="$T/root/bin"
mkdir -p "$BIN"
cp -r "$ROOT/helpers" "$T/root/"
cp -r "$ROOT/release" "$T/root/"
cp "$ROOT/bin/promote-channel" "$ROOT/bin/publish-artifact" "$BIN/"
PKGBUILDS_DIR="$T/root/pkgbuilds"
recipe() { # recipe <dir> <metadata json> [pkgbase] [arch]
  mkdir -p "$PKGBUILDS_DIR/$1/.omarchy"
  echo "${3:+pkgbase=$3 }pkgname=$1 arch=(${4:-x86_64})" > "$PKGBUILDS_DIR/$1/PKGBUILD"
  echo "$2" > "$PKGBUILDS_DIR/$1/.omarchy/package.json"
}
recipe alpha '{"source": "local"}'
# A directory need not be named after the pkgbase it builds.
recipe split-recipe '{"source": "local"}' split
recipe fast '{"source": "local", "release_ring": "fast"}'
recipe pinned '{"source": "local", "pinned": true}'
recipe ahead '{"source": "local"}'
recipe big '{"source": "local"}'
# Built for x86_64 once; the recipe has since dropped it.
recipe dropped '{"source": "local"}' "" aarch64

# minimal real packages via makepkg; a second name makes a split package
mkpkg() { # mkpkg <base> <pkgrel> [second pkgname]
  local d="$T/src/$1-$2"; mkdir -p "$d"; cd "$d"
  {
    if [[ -n ${3:-} ]]; then
      printf 'pkgbase=%s\npkgname=(%s %s)\n' "$1" "$1" "$3"
      printf 'package_%s(){ install -Dm644 /dev/null "$pkgdir/usr/share/%s"; }\n' "$1" "$1"
      printf 'package_%s(){ install -Dm644 /dev/null "$pkgdir/usr/share/%s"; }\n' "$3" "$3"
    else
      printf 'pkgname=%s\npackage(){ install -Dm644 /dev/null "$pkgdir/usr/share/%s-%s"; }\n' "$1" "$1" "$2"
    fi
    printf 'pkgver=1.0\npkgrel=%s\narch=(x86_64)\n' "$2"
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

pub() { # pub <mirror> <files...>
  local mirror=$1; shift
  "$BIN/publish-artifact" --remote "$REMOTE" --mirror "$mirror" --arch x86_64 "$@" >"$T/out" 2>&1 || { cat "$T/out"; exit 1; }
}
promote() { "$BIN/promote-channel" --remote "$REMOTE" --from edge --to rc --arch x86_64 --record "$T/record" "$@" >"$T/out" 2>&1; }
entries() { tar -tf "$REMOTE/$1/x86_64/omarchy.db.tar.zst" | grep '/$' | tr -d / | sort | tr '\n' ' '; }
plan_action() { jq -r --arg n "$1" 'select(.type=="plan" and .name==$n) | .action' "$T/record" | tail -1; }
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; cat "$T/out"; exit 1; }

REAL_RCLONE=$(command -v rclone)
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
cat <<RCLONE_EOF > "$FAKEBIN/rclone"
#!/bin/bash
if [[ \${1:-} == lsf && -n \${FAIL_LSF_RC:-} ]]; then
  if [[ -z \${FAIL_LSF_MATCH:-} || \${2:-} == *"\$FAIL_LSF_MATCH"* ]]; then
    [[ -n \${FAIL_LSF_STDOUT:-} ]] && printf '%s\n' "\$FAIL_LSF_STDOUT"
    echo "simulated rclone lsf failure on \${2:-} (rc=\$FAIL_LSF_RC)" >&2
    exit "\$FAIL_LSF_RC"
  fi
fi
if [[ \${1:-} == copyto && -n \${FAIL_COPYTO_RC:-} ]]; then
  if [[ -z \${FAIL_COPYTO_MATCH:-} || \${2:-} == *"\$FAIL_COPYTO_MATCH"* ]]; then
    echo "simulated rclone copyto failure on \${2:-} (rc=\$FAIL_COPYTO_RC)" >&2
    exit "\$FAIL_COPYTO_RC"
  fi
fi
exec "$REAL_RCLONE" "\$@"
RCLONE_EOF
chmod +x "$FAKEBIN/rclone"

if (( EUID == 0 )); then
  id -u fixture >/dev/null 2>&1 || useradd -m fixture
  mkdir -p "$T/src"; chmod 755 "$T/src"
fi
mkpkg_par() {
  local pids=() spec
  for spec in "$@"; do
    # shellcheck disable=SC2086
    ( mkpkg $spec >/dev/null ) &
    pids+=($!)
  done
  local p; for p in "${pids[@]}"; do wait "$p"; done
}
pkgf() { ls "$T/src/$1-$2"/*.pkg.tar.zst; }
# rc: what stable users have now. edge: newer builds of most of it.
mkpkg_par "alpha 1" "fast 1" "pinned 1" "ahead 3" \
  "alpha 2" "split 1 split-extra" "fast 2" "pinned 2" "ahead 2" "big 1" "dropped 1" \
  "alpha 3" "split 2 split-extra" "big 2" "alpha 4" "big 3"
pub rc --init $(pkgf alpha 1) $(pkgf fast 1) $(pkgf pinned 1) $(pkgf ahead 3)
pub edge --init $(pkgf alpha 2) $(pkgf split 1) $(pkgf fast 2) $(pkgf pinned 2) \
  $(pkgf ahead 2) $(pkgf big 1) $(pkgf dropped 1)
rc_before=$(entries rc)

: > "$T/record"
promote --dry-run && [[ "$(entries rc)" == "$rc_before" ]] \
  && [[ $(plan_action alpha) == promote && $(plan_action split-extra) == promote ]] \
  && pass "dry run plans the promotion and publishes nothing" || fail "dry run"

: > "$T/record"
promote || fail "promotion failed"
[[ "$(entries rc)" == "ahead-1.0-3 alpha-1.0-2 big-1.0-1 fast-1.0-1 pinned-1.0-1 split-1.0-1 split-extra-1.0-1 " ]] \
  && pass "newer and missing packages reach rc; nothing else changes" || fail "rc entries: $(entries rc)"

[[ $(plan_action fast) == hold && $(plan_action pinned) == hold && $(plan_action ahead) == hold ]] \
  && jq -e 'select(.name=="pinned") | .reason | test("pinned")' "$T/record" >/dev/null \
  && jq -e 'select(.name=="ahead") | .reason | test("rc is ahead")' "$T/record" >/dev/null \
  && jq -e 'select(.name=="dropped") | .reason | test("no longer builds for x86_64")' "$T/record" >/dev/null \
  && pass "fast ring, pinned, rc-ahead and dropped-arch packages are held back, each with its reason" || fail "hold reasons"

cmp -s "$REMOTE/edge/x86_64/alpha-1.0-2-x86_64.pkg.tar.zst" "$REMOTE/rc/x86_64/alpha-1.0-2-x86_64.pkg.tar.zst" \
  && [[ -f "$REMOTE/rc/x86_64/alpha-1.0-2-x86_64.pkg.tar.zst.sig" ]] \
  && pass "rc serves the same bytes edge does, signed" || fail "promoted bytes differ"

jq -e -s '[.[] | select(.type=="slot")] | length == 1 and .[0].status == "published" and (.[0].packages | index("split-extra-1.0-1-x86_64"))' "$T/record" >/dev/null \
  && pass "the record names every published package in its slot" || fail "slot record: $(cat "$T/record")"

: > "$T/record"
promote && grep -q 'already up to date' "$T/out" && [[ $(plan_action alpha) == current ]] \
  && pass "a second run finds nothing to do" || fail "rerun"

# Batches split between pkgbases, never inside one; each batch is a slot.
pub edge $(pkgf alpha 3) $(pkgf split 2) $(pkgf big 2)
: > "$T/record"
promote --batch-bytes 1 || fail "batched promotion failed"
jq -e -s '[.[] | select(.type=="slot")] | length == 3 and all(.status == "published")' "$T/record" >/dev/null \
  && jq -e -s '[.[] | select(.type=="slot") | .packages | select(index("split-1.0-2-x86_64"))] | length == 1 and (.[0] | index("split-extra-1.0-2-x86_64"))' "$T/record" >/dev/null \
  && [[ "$(entries rc)" == "ahead-1.0-3 alpha-1.0-3 big-1.0-2 fast-1.0-1 pinned-1.0-1 split-1.0-2 split-extra-1.0-2 " ]] \
  && pass "small batches publish base by base and keep split packages together" || fail "batches: $(cat "$T/record")"

# A named pkgbase limits the run to it.
pub edge $(pkgf alpha 4) $(pkgf big 3)
: > "$T/record"
promote alpha && [[ "$(entries rc)" == "ahead-1.0-3 alpha-1.0-4 big-1.0-2 fast-1.0-1 pinned-1.0-1 split-1.0-2 split-extra-1.0-2 " ]] \
  && pass "naming a pkgbase promotes only that one" || fail "named promotion: $(entries rc)"
if promote nosuch; then fail "an unknown pkgbase should refuse"; else grep -q 'not a pkgbase in edge/x86_64 or a recipe' "$T/out" && pass "an unknown pkgbase is refused" || fail "unknown pkgbase reason"; fi
recipe elsewhere '{"source": "local"}'
promote elsewhere && grep -q 'not in edge/x86_64; skipping' "$T/out" \
  && pass "a recipe this architecture has not published is skipped, not refused" || fail "other-arch recipe"
recipe armonly '{"source": "local"}' "" aarch64
promote armonly && grep -q 'armonly does not build for x86_64; skipping it' "$T/out" && ! grep -q 'armonly is not in' "$T/out" \
  && pass "a recipe that does not build this architecture is skipped without a warning" || fail "arch-only recipe"

# --expect: only the files that were checked may move.
pub edge $(mkpkg alpha 5)
printf '%s\n' big-1.0-3-x86_64.pkg.tar.zst > "$T/expect"
if promote --expect "$T/expect" alpha; then fail "a plan other than the checked one should refuse"; else
  grep -q 'not the one that was checked' "$T/out" && [[ "$(entries rc)" == *"alpha-1.0-4 "* ]] \
    && pass "a plan that differs from the checked files publishes nothing" || fail "--expect mismatch"
fi
printf '%s\n' alpha-1.0-5-x86_64.pkg.tar.zst > "$T/expect"
promote --expect "$T/expect" alpha && [[ "$(entries rc)" == *"alpha-1.0-5 "* ]] \
  && pass "the checked plan publishes" || fail "--expect match: $(entries rc)"

# A source file that does not match its database entry is never published.
f="$REMOTE/edge/x86_64/big-1.0-3-x86_64.pkg.tar.zst"
cp "$f" "$T/good"; echo tampered >> "$f"
: > "$T/record"
if promote big; then fail "a corrupt source file should refuse"; else
  grep -q 'does not match its database entry' "$T/out" && [[ "$(entries rc)" == *"big-1.0-2 "* ]] \
    && jq -e -s '[.[] | select(.type=="slot")] | .[0].status == "failed"' "$T/record" >/dev/null \
    && pass "a corrupt source file fails its slot and leaves rc alone" || fail "corrupt source"
fi
cp "$T/good" "$f"

if "$BIN/promote-channel" --remote "$REMOTE" --from edge --to stable --arch x86_64 >"$T/out" 2>&1; then
  fail "edge -> stable should refuse"
else grep -q 'refusing edge -> stable' "$T/out" && pass "channels only move one step forward" || fail "direction reason"; fi

# Transient rclone lsf errors on either source or destination must fail closed
# and leave the destination untouched.
rc_db_before=$(sha256sum "$REMOTE/rc/x86_64/omarchy.db.tar.zst")
if PATH="$FAKEBIN:$PATH" FAIL_LSF_RC=5 FAIL_LSF_MATCH="/edge/" promote; then
  fail "rclone lsf error on source should fail closed"
else
  grep -q "Failed to list" "$T/out" && grep -q "simulated rclone lsf failure" "$T/out" \
    && [[ "$(sha256sum "$REMOTE/rc/x86_64/omarchy.db.tar.zst")" == "$rc_db_before" ]] \
    && pass "rclone lsf error on source fails closed" || fail "source lsf error"
fi
if PATH="$FAKEBIN:$PATH" FAIL_LSF_RC=1 FAIL_LSF_MATCH="/rc/" promote; then
  fail "rclone lsf error on destination should fail closed"
else
  grep -q "Failed to list" "$T/out" && grep -q "simulated rclone lsf failure" "$T/out" \
    && [[ "$(sha256sum "$REMOTE/rc/x86_64/omarchy.db.tar.zst")" == "$rc_db_before" ]] \
    && pass "rclone lsf error on destination fails closed and preserves rc db" || fail "dest lsf error"
fi

# Brand-new destination channel (stable does not exist yet): refuse without --init
# for both missing dir and empty dir, and fail closed on non-3 rclone lsf error
# even with --init.
if "$BIN/promote-channel" --remote "$REMOTE" --from rc --to stable --arch x86_64 >"$T/out" 2>&1; then
  fail "missing destination dir without --init should refuse"
else
  grep -q "Failed to list" "$T/out" && [[ ! -e "$REMOTE/stable/x86_64/omarchy.db.tar.zst" ]] \
    && pass "promote refuses missing destination dir without --init" || fail "promote missing dest"
fi
mkdir -p "$REMOTE/stable/x86_64"
if "$BIN/promote-channel" --remote "$REMOTE" --from rc --to stable --arch x86_64 >"$T/out" 2>&1; then
  fail "empty destination without --init should refuse"
else
  grep -q -- "--init" "$T/out" && [[ ! -e "$REMOTE/stable/x86_64/omarchy.db.tar.zst" ]] \
    && pass "promote refuses empty destination without --init" || fail "promote empty dest"
fi
if PATH="$FAKEBIN:$PATH" FAIL_LSF_RC=5 FAIL_LSF_MATCH="/stable/" "$BIN/promote-channel" --init --remote "$REMOTE" --from rc --to stable --arch x86_64 >"$T/out" 2>&1; then
  fail "rclone lsf error on destination with --init should fail closed"
else
  grep -q "Failed to list" "$T/out" && [[ ! -e "$REMOTE/stable/x86_64/omarchy.db.tar.zst" ]] \
    && pass "promote with --init still fails closed on rclone lsf error" || fail "promote --init lsf error"
fi
# Partial database artifact (omarchy.db without omarchy.db.tar.zst) must be
# refused even with --init.
touch "$REMOTE/stable/x86_64/omarchy.db"
if "$BIN/promote-channel" --init --remote "$REMOTE" --from rc --to stable --arch x86_64 >"$T/out" 2>&1; then
  fail "partial db artifacts at destination should refuse even with --init"
else
  grep -q 'partial database artifacts' "$T/out" && [[ ! -e "$REMOTE/stable/x86_64/omarchy.db.tar.zst" ]] \
    && pass "promote --init refuses partial destination db artifacts" || fail "promote partial db"
fi
rm "$REMOTE/stable/x86_64/omarchy.db"
# A valid 0-entry omarchy.db.tar.zst is an initialized empty channel and must
# not abort under set -e during dry-run planning.
tar --zstd -cf "$REMOTE/stable/x86_64/omarchy.db.tar.zst" -T /dev/null
"$BIN/promote-channel" --dry-run --remote "$REMOTE" --from rc --to stable --arch x86_64 >"$T/out" 2>&1 \
  && pass "promote reads a valid empty destination db without --init" || fail "empty destination db"
rm "$REMOTE/stable/x86_64/omarchy.db.tar.zst"
rmdir "$REMOTE/stable/x86_64"

# Failed listing that already emitted omarchy.db.tar.zst must still fail closed.
if PATH="$FAKEBIN:$PATH" FAIL_LSF_RC=1 FAIL_LSF_MATCH="/rc/" FAIL_LSF_STDOUT=omarchy.db.tar.zst promote; then
  fail "failed rclone lsf emitting db name should fail closed"
else
  grep -q 'Failed to list' "$T/out" \
    && pass "promote fails closed when rclone lsf emits db name before failing" || fail "promote partial stdout"
fi

# Failed database downloads and unreadable archives on either source or
# destination must fail closed (guards against set -e being disabled on read_db)
# and leave the destination database untouched.
if PATH="$FAKEBIN:$PATH" FAIL_COPYTO_RC=1 FAIL_COPYTO_MATCH="/edge/" promote --dry-run; then
  fail "rclone copyto failure on source db should fail closed"
else
  grep -q 'simulated rclone copyto failure' "$T/out" && ! grep -q 'has .* packages' "$T/out" \
    && [[ "$(sha256sum "$REMOTE/rc/x86_64/omarchy.db.tar.zst")" == "$rc_db_before" ]] \
    && pass "rclone copyto error on source db fails closed and preserves rc db" || fail "source copyto error"
fi
if PATH="$FAKEBIN:$PATH" FAIL_COPYTO_RC=1 FAIL_COPYTO_MATCH="/rc/" promote --dry-run; then
  fail "rclone copyto failure on destination db should fail closed"
else
  grep -q 'simulated rclone copyto failure' "$T/out" && ! grep -q 'has .* packages' "$T/out" \
    && [[ "$(sha256sum "$REMOTE/rc/x86_64/omarchy.db.tar.zst")" == "$rc_db_before" ]] \
    && pass "rclone copyto error on destination db fails closed and preserves rc db" || fail "dest copyto error"
fi

cp "$REMOTE/edge/x86_64/omarchy.db.tar.zst" "$T/edge.db.bak"
printf 'not a valid archive\n' > "$REMOTE/edge/x86_64/omarchy.db.tar.zst"
if promote --dry-run; then
  cp "$T/edge.db.bak" "$REMOTE/edge/x86_64/omarchy.db.tar.zst"
  fail "corrupt source db archive should fail closed"
else
  cp "$T/edge.db.bak" "$REMOTE/edge/x86_64/omarchy.db.tar.zst"
  grep -q 'bsdtar:' "$T/out" && ! grep -q 'has .* packages' "$T/out" && [[ "$(sha256sum "$REMOTE/rc/x86_64/omarchy.db.tar.zst")" == "$rc_db_before" ]] \
    && pass "corrupt source db archive fails closed before planning and preserves rc db" || fail "corrupt source db"
fi

cp "$REMOTE/rc/x86_64/omarchy.db.tar.zst" "$T/rc.db.bak"
printf 'not a valid archive\n' > "$REMOTE/rc/x86_64/omarchy.db.tar.zst"
corrupt_rc_sum=$(sha256sum "$REMOTE/rc/x86_64/omarchy.db.tar.zst")
if promote --dry-run; then
  cp "$T/rc.db.bak" "$REMOTE/rc/x86_64/omarchy.db.tar.zst"
  fail "corrupt destination db archive should fail closed"
else
  grep -q 'bsdtar:' "$T/out" && ! grep -q 'has .* packages' "$T/out" && [[ "$(sha256sum "$REMOTE/rc/x86_64/omarchy.db.tar.zst")" == "$corrupt_rc_sum" ]] || {
    cp "$T/rc.db.bak" "$REMOTE/rc/x86_64/omarchy.db.tar.zst"
    fail "corrupt destination db reached planning or was modified"
  }
  cp "$T/rc.db.bak" "$REMOTE/rc/x86_64/omarchy.db.tar.zst"
  pass "corrupt destination db archive fails closed before planning without overwriting rc db"
fi

# rc -> stable: pinned packages move there (stable gets the release pair by
# promotion); fast-ring ones are published at merge. Use --batch-bytes 1 and
# record every publish-artifact invocation to verify only batch 1 gets --init.
mv "$BIN/publish-artifact" "$BIN/publish-artifact.real"
cat <<WRAP_EOF > "$BIN/publish-artifact"
#!/bin/bash
printf '%s\n' "\$*" >> "$T/pub-args.log"
exec "$BIN/publish-artifact.real" "\$@"
WRAP_EOF
chmod +x "$BIN/publish-artifact"
: > "$T/pub-args.log"
: > "$T/record"
"$BIN/promote-channel" --init --batch-bytes 1 --remote "$REMOTE" --from rc --to stable --arch x86_64 --record "$T/record" >"$T/out" 2>&1 || fail "rc -> stable"
mv "$BIN/publish-artifact.real" "$BIN/publish-artifact"
batch_count=$(wc -l < "$T/pub-args.log")
(( batch_count >= 2 )) && head -n 1 "$T/pub-args.log" | grep -q -- '--init' \
  && ! tail -n +2 "$T/pub-args.log" | grep -q -- '--init' \
  && pass "multi-batch promote --init passes --init only to the first batch ($batch_count batches)" || fail "batch --init args: $(cat "$T/pub-args.log")"
[[ $(plan_action pinned) == promote && $(plan_action fast) == hold ]] && [[ "$(entries stable)" == *"pinned-1.0-1 "* ]] \
  && pass "rc -> stable carries the pinned pair and holds the fast ring" || fail "stable promotion: $(entries stable)"

# --fast-ring: rc and stable catch up with edge for fast-ring packages only,
# from edge directly.
fastring() { "$BIN/promote-channel" --remote "$REMOTE" --fast-ring --from edge --arch x86_64 --record "$T/record" "$@" >"$T/out" 2>&1; }
: > "$T/record"
fastring --to rc || fail "fast-ring sync to rc"
[[ $(plan_action fast) == promote && $(plan_action alpha) == hold ]] && [[ "$(entries rc)" == *"fast-1.0-2 "* ]] \
  && jq -e 'select(.name=="alpha") | .reason == "not on the fast ring"' "$T/record" >/dev/null \
  && cmp -s "$REMOTE/edge/x86_64/fast-1.0-2-x86_64.pkg.tar.zst" "$REMOTE/rc/x86_64/fast-1.0-2-x86_64.pkg.tar.zst" \
  && pass "--fast-ring brings rc in line with edge, fast-ring packages only" || fail "fast-ring rc: $(entries rc)"
: > "$T/record"
fastring --to stable && [[ "$(entries stable)" == *"fast-1.0-2 "* ]] && [[ $(plan_action alpha) == hold ]] \
  && pass "--fast-ring goes from edge straight to stable" || fail "fast-ring stable: $(entries stable)"
: > "$T/record"
fastring --to rc && [[ $(plan_action fast) == current ]] && pass "--fast-ring is a no-op once the channels agree" || fail "fast-ring rerun"
if "$BIN/promote-channel" --remote "$REMOTE" --fast-ring --from rc --to stable --arch x86_64 >"$T/out" 2>&1; then
  fail "--fast-ring from rc should refuse"
else grep -q 'fast ring follows edge' "$T/out" && pass "--fast-ring only follows edge" || fail "fast-ring direction reason"; fi
