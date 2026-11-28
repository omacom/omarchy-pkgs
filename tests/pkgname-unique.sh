#!/bin/bash
# One pkgname is built by one directory, per architecture. Two directories that
# build the same name publish the same filenames, and whichever artifact is
# collected last wins: #1878 built linux-omarchy as pkgbase linux-omarchy-bore,
# collided with the transitional package of that name, and edge kept the stub.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
BUILD_ROOT=$ROOT
source "$BUILD_ROOT/helpers/paths.sh"
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# Print "name/arch<TAB>dir" for every pkgname each directory builds, read the
# way the build planner reads a recipe: with CARCH set for each supported
# architecture in CI_ARCHES, in an isolated subshell. Matches bin/build-matrix
# for arch=any (built once on the first architecture and published to all).
# Fails loudly if any PKGBUILD cannot be sourced or lacks pkgname/arch.
claim() {
  local root="$1"
  env -u OMARCHY_SRC bash -s "$root" "$CI_ARCHES" <<'BASH'
    __root=$1
    read -ra __arches <<<"$2"
    for __pkgdir in "$__root"/*/; do
      [[ -d $__pkgdir ]] || continue
      __dir=${__pkgdir%/}; __dir=${__dir##*/}
      for __carch in "${__arches[@]}"; do
        __out=$(
          set -e
          cd "$__pkgdir"
          export CARCH=$__carch
          source ./PKGBUILD >/dev/null
          (( ${#pkgname[@]} && ${#arch[@]} )) || {
            echo "$__dir/PKGBUILD: missing pkgname or arch (CARCH=$__carch)" >&2
            exit 1
          }
          for __pkg in "${pkgname[@]}"; do
            [[ -n $__pkg ]] || { echo "$__dir/PKGBUILD: empty pkgname (CARCH=$__carch)" >&2; exit 1; }
          done
          if [[ " ${arch[*]} " == *" any "* ]]; then
            if [[ $__carch == "${__arches[0]}" ]]; then
              printf "ANY\n"
              for __pub in "${__arches[@]}"; do
                for __pkg in "${pkgname[@]}"; do
                  printf "%s/%s\t%s\n" "$__pkg" "$__pub" "$__dir"
                done
              done
            else
              for __pkg in "${pkgname[@]}"; do
                printf "%s/%s\t%s\n" "$__pkg" "$__carch" "$__dir"
              done
            fi
          elif [[ " ${arch[*]} " == *" $__carch "* ]]; then
            for __pkg in "${pkgname[@]}"; do
              printf "%s/%s\t%s\n" "$__pkg" "$__carch" "$__dir"
            done
          fi
        )
        if (( $? != 0 )); then
          echo "failed to read $__dir/PKGBUILD (CARCH=$__carch)" >&2
          exit 1
        fi
        if [[ $__out == ANY$'\n'* ]]; then
          printf "%s\n" "${__out#ANY$'\n'}"
          break
        fi
        [[ -z $__out ]] || printf "%s\n" "$__out"
      done
    done
BASH
}

# Name every name/arch that more than one directory builds.
collisions() {
  claim "$1" | sort -u | awk -F'\t' '
    $1 != key { if (count > 1) print key ": built by" dirs; key = $1; dirs = ""; count = 0 }
    { dirs = dirs " " $2; count++ }
    END { if (count > 1) print key ": built by" dirs }
  '
}

out=$(collisions "$ROOT/pkgbuilds")
[[ -z $out ]] && pass "each pkgname is built by one directory per architecture" \
  || fail "$out"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for dir in one two; do
  mkdir -p "$T/dup/$dir"
  printf 'pkgname=(clash)\narch=(x86_64)\n' >"$T/dup/$dir/PKGBUILD"
done
out=$(collisions "$T/dup")
[[ $out == *"clash/x86_64: built by one two"* ]] && pass "a name built twice is refused" \
  || fail "the duplicate was not reported: ${out:-nothing}"

mkdir -p "$T/carch/one" "$T/carch/two"
printf 'arch=(x86_64 aarch64)\nif [[ $CARCH == aarch64 ]]; then pkgname=(clash); else pkgname=(other); fi\n' >"$T/carch/one/PKGBUILD"
printf 'pkgname=(clash)\narch=(aarch64)\n' >"$T/carch/two/PKGBUILD"
out=$(collisions "$T/carch")
[[ $out == "clash/aarch64: built by one two" ]] && pass "an arch-conditional duplicate is refused" \
  || fail "the CARCH duplicate was not reported: ${out:-nothing}"

mkdir -p "$T/any/one" "$T/any/two"
printf 'arch=(any)\nif [[ $CARCH == x86_64 ]]; then pkgname=(clash); else pkgname=(other); fi\n' >"$T/any/one/PKGBUILD"
printf 'pkgname=(clash)\narch=(aarch64)\n' >"$T/any/two/PKGBUILD"
out=$(collisions "$T/any")
[[ $out == "clash/aarch64: built by one two" ]] && pass "an arch=any collision across architectures is refused" \
  || fail "the arch=any collision was not reported: ${out:-nothing}"

mkdir -p "$T/broken/bad"
printf 'pkgname=(unclosed\n' >"$T/broken/bad/PKGBUILD"
! collisions "$T/broken" >/dev/null 2>&1 \
  && pass "a PKGBUILD with a syntax error fails the check" \
  || fail "a syntax-error PKGBUILD was silently skipped"

mkdir -p "$T/midfail/bad"
printf 'false\npkgname=(ok)\narch=(any)\n' >"$T/midfail/bad/PKGBUILD"
! collisions "$T/midfail" >/dev/null 2>&1 \
  && pass "a PKGBUILD with a failing top-level command fails the check" \
  || fail "a mid-file failing PKGBUILD was silently skipped"

mkdir -p "$T/ret1/bad"
printf 'pkgname=(ok)\narch=(any)\nreturn 1\n' >"$T/ret1/bad/PKGBUILD"
! collisions "$T/ret1" >/dev/null 2>&1 \
  && pass "a PKGBUILD that returns non-zero after declaring metadata fails the check" \
  || fail "a failing PKGBUILD was silently skipped"
