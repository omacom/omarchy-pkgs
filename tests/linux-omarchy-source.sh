#!/bin/bash
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
CARCH=aarch64
source "$ROOT/pkgbuilds/linux-omarchy-aarch64/PKGBUILD"
[[ " ${pkgname[*]} " == *" linux-omarchy-aarch64-source "* ]]
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
startdir=$scratch/recipe
srcdir=$scratch/inputs
pkgdir=$scratch/package
mkdir -p "$startdir" "$srcdir/$_srcname" "$pkgdir"
cp "$ROOT/pkgbuilds/linux-omarchy-aarch64/PKGBUILD" "$startdir/PKGBUILD"
source=(linux.tar.xz public.patch)
source_aarch64=(config.aarch64)
for input in "${source[@]}" "${source_aarch64[@]}"; do
  echo "$input" > "$srcdir/$input"
done
mv "$srcdir/linux.tar.xz" "$startdir/linux.tar.xz"
echo config > "$srcdir/$_srcname/.config"
echo release > "$srcdir/$_srcname/version"
echo private > "$srcdir/vendor-firmware.exe"
_package-aarch64-source
cd "$pkgdir/usr/src/$pkgbase"
sha256sum -c SHA256SUMS
[[ -f linux.tar.xz && -f PKGBUILD && -f BUILD_CONFIG && -f KERNEL_RELEASE ]]
[[ ! -e vendor-firmware.exe ]]
echo 'PASS: complete declared source inputs and recipe are packaged; unrelated vendor files are excluded'
