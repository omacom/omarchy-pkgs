#!/bin/bash
set -euo pipefail

# Every x86_64 linux-omarchy recipe ships OpenRazer's modules prebuilt as
# $kernel-openrazer, and openrazer-driver ships the udev rules that bind them
# and open their controls to the openrazer group. Keep both on one release so
# the rules never name a device the modules do not drive.

REPO_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
PKGBUILDS=${1:-"$REPO_ROOT/pkgbuilds"}
KERNELS=(linux-omarchy linux-omarchy-eevdf linux-omarchy-muqss)

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Sourcing reads the recipes' variables without running any of their functions.
recipe() {
  (CARCH=x86_64; source "$1/PKGBUILD"; eval "$2")
}

version=$(recipe "$PKGBUILDS/openrazer-driver" 'echo "$pkgver"')

for kernel in "${KERNELS[@]}"; do
  found=$(recipe "$PKGBUILDS/$kernel" 'echo "$_openrazerver"')
  [[ $found == "$version" ]] || fail "$kernel builds OpenRazer ${found:-nothing}, openrazer-driver is $version"
done

echo "OpenRazer $version in step between openrazer-driver and ${#KERNELS[@]} kernels"
