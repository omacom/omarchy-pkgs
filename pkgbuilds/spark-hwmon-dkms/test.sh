#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

# shellcheck disable=SC1091
source "$package_dir/PKGBUILD"

srcdir="$scratch/src dir"
pkgdir="$scratch/pkg dir"
# shellcheck disable=SC2154
mkdir -p "$srcdir/$_srcname"
cp "$package_dir/dkms.conf" "$srcdir/dkms.conf"
printf '/* stub */\n' >"$srcdir/$_srcname/spbm.c"
printf 'obj-m += spbm.o\n' >"$srcdir/$_srcname/Makefile"

package

# shellcheck disable=SC2154
dkms_conf="$pkgdir/usr/src/spbm-${pkgver}/dkms.conf"
[[ -f "$dkms_conf" ]] || fail "packaged dkms.conf missing at $dkms_conf"

(
  unset PACKAGE_NAME PACKAGE_VERSION AUTOINSTALL BUILD_EXCLUSIVE_KERNEL_MIN MAKE
  # shellcheck disable=SC1090
  source "$dkms_conf"
  [[ "${PACKAGE_NAME:-}" == "spbm" ]] || fail "bad PACKAGE_NAME: ${PACKAGE_NAME:-<unset>}"
  [[ "${PACKAGE_VERSION:-}" == "$pkgver" ]] || fail "bad PACKAGE_VERSION: ${PACKAGE_VERSION:-<unset>}"
  [[ "${AUTOINSTALL:-}" == "yes" ]] || fail "bad AUTOINSTALL: ${AUTOINSTALL:-<unset>}"
  [[ "${BUILD_EXCLUSIVE_KERNEL_MIN:-}" == "7.3" ]] || fail "bad BUILD_EXCLUSIVE_KERNEL_MIN: ${BUILD_EXCLUSIVE_KERNEL_MIN:-<unset>}"
  ! declare -p MAKE >/dev/null 2>&1 || fail "redundant MAKE directive should be omitted"
)

# Exercise check() with multiple installed kernel header trees under a path
# with spaces and a symlinked root: it must select the tree referenced by
# /usr/src/linux-omarchy and preserve exact argv boundaries.
real_root="$scratch/root dir"
mkdir -p \
  "$real_root/usr/lib/modules/7.2.12-1-omarchy/build" \
  "$real_root/usr/lib/modules/7.3.6-13-omarchy/build" \
  "$real_root/usr/lib/modules/7.3.6-13-omarchy/nested/build" \
  "$real_root/usr/src"
ln -s ../lib/modules/7.3.6-13-omarchy/build "$real_root/usr/src/linux-omarchy"
ln -s "$real_root" "$scratch/-root-link"
_check_root="-root-link"

dkms_log="$scratch/dkms.log"
fakeroot() {
  printf '%s\n' "$@" "---" >>"$dkms_log"
}
(cd "$scratch" && check)

expected_log=$(printf '%s\n' \
  dkms --dkmstree "$srcdir/check/dkms" --sourcetree "$srcdir/check/src" -k 7.3.6-13-omarchy add "$srcdir/check-src/spbm-$pkgver" --- \
  dkms --dkmstree "$srcdir/check/dkms" --sourcetree "$srcdir/check/src" -k 7.3.6-13-omarchy build "spbm/$pkgver" ---)
actual_log=$(<"$dkms_log")
[[ "$actual_log" == "$expected_log" ]] ||
  fail "unexpected dkms invocations:\n$actual_log\nexpected:\n$expected_log"

# Nested path under modules/<kver>/nested/build must be rejected.
ln -sfn ../lib/modules/7.3.6-13-omarchy/nested/build "$real_root/usr/src/linux-omarchy"
if err=$(cd "$scratch" && check 2>&1); then
  fail "check() succeeded with nested build path under /usr/src/linux-omarchy"
fi
[[ "$err" == *"linux-omarchy-headers build directory not found"* ]] ||
  fail "unexpected diagnostic on nested build path: $err"

# Dangling /usr/src/linux-omarchy link pointing to a missing build/ under an
# existing kernel directory must fail the directory check with a clear message.
mkdir -p "$real_root/usr/lib/modules/7.3.7-1-omarchy"
ln -sfn ../lib/modules/7.3.7-1-omarchy/build "$real_root/usr/src/linux-omarchy"
if err=$(cd "$scratch" && check 2>&1); then
  fail "check() succeeded with missing build directory under /usr/src/linux-omarchy"
fi
[[ "$err" == *"linux-omarchy-headers build directory not found"* ]] ||
  fail "unexpected diagnostic on missing build directory: $err"

# Missing _check_root must fail closed even when errexit is inactive (never
# falling back to host headers).
: >"$dkms_log"
_check_root="$scratch/nonexistent/child"
if err=$(check 2>&1); then
  fail "check() succeeded with missing _check_root"
fi
[[ "$err" == *"check root directory not found"* ]] ||
  fail "unexpected diagnostic on missing _check_root: $err"
[[ ! -s "$dkms_log" ]] || fail "check() invoked dkms despite missing _check_root"

# _check_root=/ must normalize away the trailing slash so it probes
# /usr/src/linux-omarchy rather than //usr/src/linux-omarchy.
if err=$(
  _check_root=/
  # shellcheck disable=SC2329
  readlink() {
    [[ $# -eq 3 && $1 == -f && $2 == -- ]] || { echo "unexpected readlink args: $*" >&2; return 2; }
    case "$3" in
      /) printf '/\n' ;;
      /usr/src/linux-omarchy) return 1 ;;
      *) echo "unexpected readlink path: $3" >&2; return 2 ;;
    esac
  }
  check 2>&1
); then
  fail "check() succeeded with unresolved /usr/src/linux-omarchy under _check_root=/"
fi
[[ "$err" == "linux-omarchy-headers build directory not found at /usr/src/linux-omarchy" ]] ||
  fail "unexpected diagnostic for _check_root=/: $err"

echo "ok - spark-hwmon-dkms"
