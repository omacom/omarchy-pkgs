#!/bin/bash
set -euo pipefail
source "$(dirname "$(realpath "$0")")/PKGBUILD"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
srcdir="$work/src"
mkdir -p "$srcdir" "$work/payload/usr/bin" "$work/payload/etc/udev/rules.d"
for binary in openlogi openlogi-agent openlogi-desktop openlogi-overlay; do
  printf '#!/bin/sh\nexit 0\n' > "$work/payload/usr/bin/$binary"
  chmod 755 "$work/payload/usr/bin/$binary"
done
printf 'SUBSYSTEM=="hidraw", TAG+="uaccess"\n' > "$work/payload/etc/udev/rules.d/70-openlogi.rules"
printf 'upstream package metadata\n' > "$work/payload/.PKGINFO"
cp "$work/payload/.PKGINFO" "$work/payload/.INSTALL"
for CARCH in "${arch[@]}"; do
  pkgdir="$work/$CARCH"
  mkdir -p "$pkgdir"
  bsdtar -cf "$srcdir/$pkgname-$pkgver-$CARCH.pkg.tar.zst" -C "$work/payload" usr etc .PKGINFO .INSTALL
  package
  for binary in openlogi openlogi-agent openlogi-desktop openlogi-overlay; do
    test -x "$pkgdir/usr/bin/$binary"
  done
  cmp "$work/payload/etc/udev/rules.d/70-openlogi.rules" "$pkgdir/usr/lib/udev/rules.d/70-openlogi.rules"
  test ! -e "$pkgdir/etc"
  test ! -e "$pkgdir/.PKGINFO"
  test ! -e "$pkgdir/.INSTALL"
done
echo 'PASS: both architectures preserve binaries, relocate udev rules, and exclude upstream package metadata'
