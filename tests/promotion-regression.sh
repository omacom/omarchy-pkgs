#!/bin/bash
# Promotions that touch no Mac package give the same result with the Mac
# package-set check as without it. Runs one x86_64 and one aarch64 (non-Mac)
# fixture through the promotion tooling of a baseline commit and through this
# checkout's, from identical channels, and requires the same exit code, the
# same plan (what moves, what is held and why), the same publishes and the
# same channel databases at every step.
#
#   BASELINE_REF=<commit> tests/promotion-regression.sh   (git archive of bin/ and helpers/)
#   BASELINE_ROOT=<dir>   tests/promotion-regression.sh   (a tree holding bin/ and helpers/)
#
# CI pins BASELINE_REF to be8ab9bd, the master commit before the check. The
# check's own record line ({"type":"mac-set"}) exists only with the change
# and must read "untouched"; it is set aside before comparing.
# Needs repo-add, gpg, rclone, bsdtar, vercmp, git (the Arch test container).
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); chmod 755 "$T"; trap 'rm -rf "$T"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# --- the two toolings ---------------------------------------------------------
mkdir -p "$T/before" "$T/after"
if [[ -n ${BASELINE_ROOT:-} ]]; then
  cp -r "$BASELINE_ROOT/bin" "$BASELINE_ROOT/helpers" "$T/before/"
elif [[ -n ${BASELINE_REF:-} ]]; then
  git -c safe.directory='*' -C "$ROOT" archive "$BASELINE_REF" bin helpers | tar -x -C "$T/before"
else
  fail "set BASELINE_REF or BASELINE_ROOT to the tooling to compare against"
fi
[[ ! -e $T/before/bin/check-mac-set ]] || echo "note: the baseline already has bin/check-mac-set"
cp -r "$ROOT/bin" "$ROOT/helpers" "$ROOT/release" "$T/after/"
# Both read recipes from their own checkout; give them the same fixtures.
recipe() { # recipe <dir> <metadata json> <arch...>
  local dir=$1 meta=$2 side; shift 2
  for side in before after; do
    mkdir -p "$T/$side/pkgbuilds/$dir/.omarchy"
    echo "pkgname=$dir arch=($*)" > "$T/$side/pkgbuilds/$dir/PKGBUILD"
    echo "$meta" > "$T/$side/pkgbuilds/$dir/.omarchy/package.json"
  done
}
recipe alpha '{"source": "local"}' x86_64
recipe x86-split '{"source": "local"}' x86_64
recipe shared-lib '{"source": "local"}' x86_64 aarch64
recipe docs '{"source": "local"}' any
recipe fast '{"source": "local", "release_ring": "fast"}' x86_64 aarch64
recipe pinned '{"source": "local", "pinned": true}' x86_64 aarch64
recipe arm-tool '{"source": "local"}' aarch64
recipe arm-ahead '{"source": "local"}' aarch64
# Mac pkgbases the real inventory lists, on aarch64 only, for the run that
# names non-Mac packages while edge's Mac stack is ahead of rc.
recipe linux-aurora '{"source": "local"}' aarch64
recipe omarchy-mac '{"source": "local"}' aarch64

export GNUPGHOME="$T/g"; mkdir -m700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Test <t@t>' ed25519 sign 0 2>/dev/null
export GPG_PRIVATE_KEY=$(gpg --batch --armor --export-secret-keys 'Test <t@t>') GPG_PASSPHRASE=''
unset GNUPGHOME

# --- identical package files for both --------------------------------------------
mkpkg() { # mkpkg <name> <pkgrel> <arch> [second pkgname] [depends...]
  local name=$1 rel=$2 arch=$3 extra=${4:-} d="$T/src/$1-$2-$3" carch=$3
  shift 3; (( $# )) && shift
  mkdir -p "$d"; cd "$d"
  {
    if [[ -n $extra ]]; then
      printf 'pkgbase=%s\npkgname=(%s %s)\n' "$name" "$name" "$extra"
      printf 'package_%s(){ install -Dm644 /dev/null "$pkgdir/usr/share/%s"; }\n' "$name" "$name"
      printf 'package_%s(){ install -Dm644 /dev/null "$pkgdir/usr/share/%s"; }\n' "$extra" "$extra"
    else
      printf 'pkgname=%s\npackage(){ install -Dm644 /dev/null "$pkgdir/usr/share/%s-%s"; }\n' "$name" "$name" "$rel"
    fi
    printf 'pkgver=1.0\npkgrel=%s\narch=(%s)\ndepends=(' "$rel" "$arch"
    (( $# )) && printf "'%s' " "$@"
    printf ')\n'
  } > PKGBUILD
  [[ $carch == any ]] && carch=x86_64
  if (( EUID == 0 )); then
    id -u fixture >/dev/null 2>&1 || useradd -m fixture
    chmod 755 "$T/src"; chown -R fixture "$d"
    runuser -u fixture -- env CARCH=$carch PKGEXT=.pkg.tar.zst makepkg -f --nodeps --ignorearch >/dev/null 2>&1
  else
    CARCH=$carch PKGEXT=.pkg.tar.zst makepkg -f --nodeps --ignorearch >/dev/null 2>&1
  fi
  cd "$ROOT"
  ls "$d"/*.pkg.tar.zst
}
# x86_64: what an x86-only promotion sees.
X86_RC=$(mkpkg alpha 1 x86_64; mkpkg shared-lib 1 x86_64; mkpkg fast 1 x86_64; mkpkg pinned 1 x86_64; mkpkg docs 1 any)
X86_EDGE=$(mkpkg alpha 2 x86_64; mkpkg x86-split 1 x86_64 x86-split-extra; mkpkg shared-lib 2 x86_64;
  mkpkg fast 2 x86_64; mkpkg pinned 2 x86_64; mkpkg docs 2 any)
# aarch64 without Mac packages.
ARM_RC=$(mkpkg arm-tool 1 aarch64; mkpkg shared-lib 1 aarch64; mkpkg fast 1 aarch64; mkpkg arm-ahead 3 aarch64; mkpkg docs 1 any)
ARM_EDGE=$(mkpkg arm-tool 2 aarch64; mkpkg shared-lib 2 aarch64; mkpkg fast 2 aarch64; mkpkg arm-ahead 2 aarch64; mkpkg docs 2 any)
# aarch64 with a Mac stack on edge ahead of rc's.
MAC_RC=$(mkpkg linux-aurora 1 aarch64; mkpkg omarchy-mac 1 aarch64 "" 'shared-lib>=1.0'; mkpkg shared-lib 1 aarch64; mkpkg arm-tool 1 aarch64)
MAC_EDGE=$(mkpkg linux-aurora 2 aarch64; mkpkg omarchy-mac 2 aarch64 "" 'shared-lib>=1.0'; mkpkg shared-lib 2 aarch64; mkpkg arm-tool 2 aarch64)

# --- run the same promotions with each -----------------------------------------
# One line per step: the step, the exit code, then the plan, the publishes
# and the destination's database entries, each normalised and sorted.
run_side() { # run_side <before|after>
  local side=$1
  local bin="$T/$side/bin" remote="$T/$side-r2" out="$T/$side.result"
  : > "$out"
  pub() { # pub <mirror> <arch> <files...>
    local mirror=$1 arch=$2; shift 2
    "$bin/publish-artifact" --remote "$remote" --mirror "$mirror" --arch "$arch" "$@" >"$T/$side.log" 2>&1 || { cat "$T/$side.log"; fail "$side: fixture publish"; }
  }
  step() { # step <label> <promote-channel args...>
    local label=$1 code=0 to arch
    shift
    : > "$T/$side.record"
    "$bin/promote-channel" --remote "$remote" --record "$T/$side.record" "$@" >"$T/$side.log" 2>&1 || code=$?
    to=$(sed -n 's/.*--to \([a-z]*\).*/\1/p' <<<" $* ") arch=$(sed -n 's/.*--arch \([a-z0-9_]*\).*/\1/p' <<<" $* ")
    jq -c 'select(.type == "mac-set")' "$T/$side.record" >> "$T/$side.macset"
    {
      echo "== $label: exit $code"
      jq -c 'select(.type == "plan") | {arch, name, from_version, to_version, action, reason}' "$T/$side.record" | sort
      jq -c 'select(.type == "slot") | {mirror, arch, status, packages: (.packages | sort)}' "$T/$side.record" | sort
      echo "$to/$arch: $(tar -tf "$remote/$to/$arch/omarchy.db.tar.zst" 2>/dev/null | grep '/$' | tr -d / | sort | tr '\n' ' ')"
    } >> "$out"
  }
  : > "$T/$side.macset"
  pub rc x86_64 $X86_RC
  pub edge x86_64 $X86_EDGE
  step "x86_64 whole channel edge -> rc" --from edge --to rc --arch x86_64
  step "x86_64 named edge -> rc (nothing left)" --from edge --to rc --arch x86_64 alpha
  step "x86_64 rc -> stable" --from rc --to stable --arch x86_64
  step "x86_64 fast ring edge -> stable" --fast-ring --from edge --to stable --arch x86_64
  pub rc aarch64 $ARM_RC
  pub edge aarch64 $ARM_EDGE
  step "aarch64 dry run edge -> rc" --from edge --to rc --arch aarch64 --dry-run
  step "aarch64 whole channel edge -> rc" --from edge --to rc --arch aarch64
  step "aarch64 rc -> stable" --from rc --to stable --arch aarch64
  step "aarch64 fast ring edge -> rc" --fast-ring --from edge --to rc --arch aarch64
  remote="$T/$side-mac-r2"
  pub rc aarch64 $MAC_RC
  pub edge aarch64 $MAC_EDGE
  step "aarch64 named non-Mac edge -> rc, Mac stack ahead on edge" --from edge --to rc --arch aarch64 arm-tool
}
run_side before
run_side after
cat "$T/after.result"

if diff -u "$T/before.result" "$T/after.result" > "$T/diff"; then
  pass "x86_64 and aarch64 non-Mac promotions: same exit codes, plans, publishes and databases with and without the check ($(grep -c '^== ' "$T/after.result") steps)"
else
  cat "$T/diff"; fail "promotion results differ with the check"
fi
[[ ! -s $T/before.macset ]] && [[ $(jq -r .result "$T/after.macset" | sort -u) == untouched ]] \
  && pass "the check reads every one of those promotions as untouched" || { cat "$T/after.macset"; fail "mac-set results"; }
