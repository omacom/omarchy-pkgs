#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

check_pkgver() (
  local override_ver=${1:-}
  local run_dir="$scratch/run-${override_ver:-default}"
  srcdir="$run_dir/src"
  pkgdir="$run_dir/pkg"
  mkdir -p "$srcdir" "$pkgdir"

  cp "$package_dir"/{spi-pxa2xx-pci-nodma.c,spi-pxa2xx.h,Makefile,dkms.conf,macbook8-spi-nodma.conf} "$srcdir/"

  # shellcheck disable=SC1091
  source "$package_dir/PKGBUILD"
  if [[ -n "$override_ver" ]]; then
    pkgver="$override_ver"
  fi
  package

  # shellcheck disable=SC2154
  dkms_conf="$pkgdir/usr/src/${_pkgbase}-${pkgver}/dkms.conf"
  [[ -f "$dkms_conf" ]] || fail "packaged dkms.conf missing at $dkms_conf"

  unset PACKAGE_NAME PACKAGE_VERSION AUTOINSTALL
  # shellcheck disable=SC1090
  source "$dkms_conf"
  [[ "${PACKAGE_NAME:-}" == "$_pkgbase" ]] || fail "bad PACKAGE_NAME: ${PACKAGE_NAME:-<unset>}"
  [[ "${PACKAGE_VERSION:-}" == "$pkgver" ]] || fail "bad PACKAGE_VERSION: ${PACKAGE_VERSION:-<unset>} (expected $pkgver)"
  [[ "${AUTOINSTALL:-}" == "yes" ]] || fail "bad AUTOINSTALL: ${AUTOINSTALL:-<unset>}"
)

check_pkgver
check_pkgver "2.3"

echo "ok - macbook8-spi-pxa2xx-nodma-dkms"
