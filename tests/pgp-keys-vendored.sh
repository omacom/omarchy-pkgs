#!/bin/bash
# Every key a recipe trusts ships with it in keys/pgp/. A build never asks a
# keyserver: on 11 November 2026 keyserver.ubuntu.com stopped answering, each
# build waited on gpg --receive-keys with no timeout, and stuck builds held
# every builder for hours.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
BUILD_ROOT=$ROOT
source "$BUILD_ROOT/helpers/paths.sh"
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }
T=$(mktemp -d)
GNUPGHOME="$T/gnupg"
mkdir -m 700 "$GNUPGHOME"
export GNUPGHOME
trap 'rm -rf "$T"' EXIT

# The primary-key fingerprints a key file holds, one per line.
primaries() {
  gpg --show-keys --with-colons "$1" 2>/dev/null |
    awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }'
}

# Check every validpgpkeys entry across supported CARCH values directly against
# keys/pgp/<FINGERPRINT>.asc. Fails loudly if any PKGBUILD cannot be sourced.
missing_recipe_keys() {
  env -u OMARCHY_SRC bash -c '
    __root=$1
    read -ra __arches <<<"$2"
    for __pkgdir in "$__root"/*/; do
      [[ -d $__pkgdir ]] || continue
      __pkg=${__pkgdir%/}; __pkg=${__pkg##*/}
      for __carch in "${__arches[@]}"; do
        (
          set -e
          cd "$__pkgdir"
          export CARCH=$__carch
          source ./PKGBUILD >/dev/null
          for __key in "${validpgpkeys[@]}"; do
            [[ $__key =~ ^[0-9A-F]{40}$ && -f keys/pgp/$__key.asc ]] ||
              printf "  %s: validpgpkeys %s has no keys/pgp/%s.asc\n" "$__pkg" "${__key:-<empty>}" "$__key"
          done
        )
        if (( $? != 0 )); then
          echo "failed to source $__pkg/PKGBUILD (CARCH=$__carch)" >&2
          exit 1
        fi
      done
    done
  ' _ "$1" "$CI_ARCHES" | sort -u
}

check_pkgbuilds() {
  local root=$1 problems="" pkgdir pkg file name got missing
  for pkgdir in "$root"/*/; do
    [[ -d $pkgdir ]] || continue
    pkg=$(basename "$pkgdir")
    # bin/refresh-pgp-keys reads the fingerprint from the file name, so each
    # file must be <FINGERPRINT>.asc and hold that one primary key.
    for file in "$pkgdir"keys/pgp/*.asc; do
      [[ -e $file ]] || continue
      name=$(basename "$file" .asc)
      got=$(primaries "$file") || got=""
      [[ $got == "$name" ]] ||
        problems+="  $pkg: keys/pgp/$name.asc must hold exactly the primary key $name"$'\n'
    done
  done
  missing=$(missing_recipe_keys "$root") || return 1
  [[ -z $missing ]] || problems+="$missing"$'\n'
  if [[ -n $problems ]]; then
    printf '%s' "$problems"
    return 1
  fi
}

if ! out=$(check_pkgbuilds "$ROOT/pkgbuilds"); then
  printf 'FAIL: shipped signing keys:\n%s' "$out"
  exit 1
fi
pass "every validpgpkeys entry ships as keys/pgp/<FINGERPRINT>.asc holding that key"

mkdir -p "$T/carch/pkg"
printf 'if [[ $CARCH == aarch64 ]]; then validpgpkeys=(AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA); fi\n' >"$T/carch/pkg/PKGBUILD"
if out=$(check_pkgbuilds "$T/carch"); then
  fail "arch-conditional validpgpkeys was not checked"
fi
[[ $out == *"pkg: validpgpkeys AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA has no keys/pgp/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.asc"* ]] \
  && pass "an arch-conditional validpgpkeys entry without a vendored key is refused" \
  || fail "unexpected output for arch-conditional key: ${out:-nothing}"

mkdir -p "$T/broken/bad"
printf 'validpgpkeys=(unclosed\n' >"$T/broken/bad/PKGBUILD"
! check_pkgbuilds "$T/broken" >/dev/null 2>&1 \
  && pass "a PKGBUILD with a syntax error fails the check" \
  || fail "a syntax-error PKGBUILD was silently skipped"

mkdir -p "$T/midfail/bad"
printf 'false\npkgname=(ok)\narch=(any)\n' >"$T/midfail/bad/PKGBUILD"
! check_pkgbuilds "$T/midfail" >/dev/null 2>&1 \
  && pass "a PKGBUILD with a failing top-level command fails the check" \
  || fail "a mid-file failing PKGBUILD was silently skipped"

mkdir -p "$T/ret1/bad"
printf 'pkgname=(ok)\narch=(any)\nreturn 1\n' >"$T/ret1/bad/PKGBUILD"
! check_pkgbuilds "$T/ret1" >/dev/null 2>&1 \
  && pass "a PKGBUILD that returns non-zero after declaring metadata fails the check" \
  || fail "a failing PKGBUILD was silently skipped"
