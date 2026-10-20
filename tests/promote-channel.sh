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
recipe edgeonly '{"source": "local", "channels": ["edge"]}'
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

# rc: what stable users have now. edge: newer builds of most of it.
pub rc $(mkpkg alpha 1) $(mkpkg fast 1) $(mkpkg pinned 1) $(mkpkg ahead 3)
pub edge $(mkpkg alpha 2) $(mkpkg split 1 split-extra) $(mkpkg fast 2) $(mkpkg pinned 2) \
  $(mkpkg edgeonly 1) $(mkpkg ahead 2) $(mkpkg big 1) $(mkpkg dropped 1)
rc_before=$(entries rc)

: > "$T/record"
promote --dry-run && [[ "$(entries rc)" == "$rc_before" ]] \
  && [[ $(plan_action alpha) == promote && $(plan_action split-extra) == promote ]] \
  && pass "dry run plans the promotion and publishes nothing" || fail "dry run"

: > "$T/record"
promote || fail "promotion failed"
[[ "$(entries rc)" == "ahead-1.0-3 alpha-1.0-2 big-1.0-1 fast-1.0-1 pinned-1.0-1 split-1.0-1 split-extra-1.0-1 " ]] \
  && pass "newer and missing packages reach rc; nothing else changes" || fail "rc entries: $(entries rc)"

[[ $(plan_action fast) == hold && $(plan_action pinned) == hold && $(plan_action edgeonly) == hold && $(plan_action ahead) == hold ]] \
  && jq -e 'select(.name=="pinned") | .reason | test("pinned")' "$T/record" >/dev/null \
  && jq -e 'select(.name=="edgeonly") | .reason | test("channels exclude rc")' "$T/record" >/dev/null \
  && jq -e 'select(.name=="ahead") | .reason | test("rc is ahead")' "$T/record" >/dev/null \
  && jq -e 'select(.name=="dropped") | .reason | test("no longer builds for x86_64")' "$T/record" >/dev/null \
  && pass "fast ring, pinned, edge-only, rc-ahead and dropped-arch packages are held back, each with its reason" || fail "hold reasons"

cmp -s "$REMOTE/edge/x86_64/alpha-1.0-2-x86_64.pkg.tar.zst" "$REMOTE/rc/x86_64/alpha-1.0-2-x86_64.pkg.tar.zst" \
  && [[ -f "$REMOTE/rc/x86_64/alpha-1.0-2-x86_64.pkg.tar.zst.sig" ]] \
  && pass "rc serves the same bytes edge does, signed" || fail "promoted bytes differ"

jq -e -s '[.[] | select(.type=="slot")] | length == 1 and .[0].status == "published" and (.[0].packages | index("split-extra-1.0-1-x86_64"))' "$T/record" >/dev/null \
  && pass "the record names every published package in its slot" || fail "slot record: $(cat "$T/record")"

: > "$T/record"
promote && grep -q 'already up to date' "$T/out" && [[ $(plan_action alpha) == current ]] \
  && pass "a second run finds nothing to do" || fail "rerun"

# Batches split between pkgbases, never inside one; each batch is a slot.
pub edge $(mkpkg alpha 3) $(mkpkg split 2 split-extra) $(mkpkg big 2)
: > "$T/record"
promote --batch-bytes 1 || fail "batched promotion failed"
jq -e -s '[.[] | select(.type=="slot")] | length == 3 and all(.status == "published")' "$T/record" >/dev/null \
  && jq -e -s '[.[] | select(.type=="slot") | .packages | select(index("split-1.0-2-x86_64"))] | length == 1 and (.[0] | index("split-extra-1.0-2-x86_64"))' "$T/record" >/dev/null \
  && [[ "$(entries rc)" == "ahead-1.0-3 alpha-1.0-3 big-1.0-2 fast-1.0-1 pinned-1.0-1 split-1.0-2 split-extra-1.0-2 " ]] \
  && pass "small batches publish base by base and keep split packages together" || fail "batches: $(cat "$T/record")"

# A named pkgbase limits the run to it.
pub edge $(mkpkg alpha 4) $(mkpkg big 3)
: > "$T/record"
promote alpha && [[ "$(entries rc)" == "ahead-1.0-3 alpha-1.0-4 big-1.0-2 fast-1.0-1 pinned-1.0-1 split-1.0-2 split-extra-1.0-2 " ]] \
  && pass "naming a pkgbase promotes only that one" || fail "named promotion: $(entries rc)"
if promote nosuch; then fail "an unknown pkgbase should refuse"; else grep -q 'not a pkgbase in edge/x86_64 or a recipe' "$T/out" && pass "an unknown pkgbase is refused" || fail "unknown pkgbase reason"; fi
recipe elsewhere '{"source": "local"}'
promote elsewhere && grep -q 'not in edge/x86_64; skipping' "$T/out" \
  && pass "a recipe this architecture has not published is skipped, not refused" || fail "other-arch recipe"

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

# rc -> stable: pinned packages move there (stable gets the release pair by
# promotion); fast-ring ones are published at merge.
: > "$T/record"
"$BIN/promote-channel" --remote "$REMOTE" --from rc --to stable --arch x86_64 --record "$T/record" >"$T/out" 2>&1 || fail "rc -> stable"
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
