#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

# shellcheck source=PKGBUILD
source "$package_dir/PKGBUILD"

srcdir="$scratch/src"
pkgdir="$scratch/pkg"
extracted="$srcdir/${_reponame}-v${pkgver}-patched.${_patchrel}-fixture"

mkdir -p \
  "$extracted/src/tuxedo_io" \
  "$extracted/files/usr/lib/modprobe.d" \
  "$extracted/files/usr/lib/udev/rules.d" \
  "$extracted/files/usr/lib/udev/hwdb.d"

cp "$package_dir/dkms.conf" "$srcdir/dkms.conf"
printf 'obj-m += clevo_acpi.o\n' >"$extracted/src/Kbuild"
printf '/* stub */\n' >"$extracted/src/clevo_acpi.c"
printf 'obj-m += tuxedo_io.o\n' >"$extracted/src/tuxedo_io/Kbuild"
printf '/* stub */\n' >"$extracted/src/tuxedo_io/tuxedo_io.c"
printf 'blacklist clevo_wmi\n' >"$extracted/files/usr/lib/modprobe.d/tuxedo-drivers.conf"
printf 'ACTION=="add", KERNEL=="null"\n' >"$extracted/files/usr/lib/udev/rules.d/99-tuxedo.rules"
printf 'evdev:name:tuxedo*\n' >"$extracted/files/usr/lib/udev/hwdb.d/61-tuxedo.hwdb"

(cd "$srcdir" && package >"$scratch/package.out")

shopt -s nullglob
src_dirs=("$pkgdir"/usr/src/*)
shopt -u nullglob

(( ${#src_dirs[@]} == 1 )) ||
  fail "expected exactly one /usr/src entry, found ${#src_dirs[@]}: ${src_dirs[*]:-<none>}"

dkms_dir="${src_dirs[0]}"
dkms_conf="$dkms_dir/dkms.conf"
[[ -f "$dkms_conf" ]] || fail "packaged dkms.conf missing at $dkms_conf"

if grep -q '#MODULE_VERSION#' "$dkms_conf"; then
  fail "packaged dkms.conf still contains unexpanded #MODULE_VERSION#"
fi

if grep -q '^PACKAGE_VERSION=' "$scratch/package.out"; then
  fail "package() wrote dkms.conf to stdout instead of editing it in place"
fi

# Validate DKMS metadata directly inside an isolated subshell so inherited
# environment variables cannot mask missing keys and multi-line values cannot
# be truncated by read.
metadata_ok=$(
  bash -euo pipefail -c '
    unset PACKAGE_NAME PACKAGE_VERSION AUTOINSTALL
    # shellcheck disable=SC1090
    source "$1" >&2
    [[ "${PACKAGE_NAME:-}" == "$2" ]] || {
      echo "not ok - dkms.conf PACKAGE_NAME (${PACKAGE_NAME:-<unset>}) does not match _pkgname ($2)" >&2
      exit 1
    }
    [[ "${PACKAGE_VERSION:-}" == "$3" ]] || {
      echo "not ok - dkms.conf PACKAGE_VERSION (${PACKAGE_VERSION:-<unset>}) does not match pkgver ($3)" >&2
      exit 1
    }
    [[ "${AUTOINSTALL:-}" == "yes" ]] || {
      echo "not ok - dkms.conf AUTOINSTALL (${AUTOINSTALL:-<unset>}) is not yes" >&2
      exit 1
    }
    printf "metadata-ok\n"
  ' _ "$dkms_conf" "$_pkgname" "$pkgver"
)
[[ "$metadata_ok" == "metadata-ok" ]] || fail "dkms.conf metadata validation exited early"

expected_dir="$pkgdir/usr/src/${_pkgname}-${pkgver}"
[[ "$dkms_dir" == "$expected_dir" ]] ||
  fail "DKMS source dir ($(basename "$dkms_dir")) must match PACKAGE_NAME-PACKAGE_VERSION (${_pkgname}-${pkgver})"

# Match the exact path regex used by Arch's /usr/share/libalpm/scripts/dkms hook.
rel_conf="/usr/src/$(basename "$dkms_dir")/dkms.conf"
if [[ ! "$rel_conf" =~ ^/usr/src/([^/]+)-([^/]+)/dkms\.conf$ ]] ||
   [[ "${BASH_REMATCH[1]}" != "$_pkgname" ]] ||
   [[ "${BASH_REMATCH[2]}" != "$pkgver" ]]; then
  fail "DKMS path $rel_conf does not parse to ${_pkgname}/${pkgver} under Arch alpm hook"
fi

for rel in \
  "usr/src/${_pkgname}-${pkgver}/Kbuild" \
  "usr/src/${_pkgname}-${pkgver}/clevo_acpi.c" \
  "usr/src/${_pkgname}-${pkgver}/tuxedo_io/Kbuild" \
  "usr/src/${_pkgname}-${pkgver}/tuxedo_io/tuxedo_io.c" \
  "usr/lib/modprobe.d/tuxedo-drivers.conf" \
  "usr/lib/udev/rules.d/99-tuxedo.rules" \
  "usr/lib/udev/hwdb.d/61-tuxedo.hwdb"; do
  [[ -f "$pkgdir/$rel" ]] || fail "expected packaged file missing: $rel"
done

echo "ok - tuxedo-drivers-nocompatcheck-dkms"
