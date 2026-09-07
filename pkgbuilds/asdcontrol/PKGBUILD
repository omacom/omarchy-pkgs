# Maintainer: Ryan Hughes <ryan@omarchy.org>
pkgname=asdcontrol
epoch=1
pkgver=0.6.0
pkgrel=2
pkgdesc="Control brightness on Apple Displays connected via USB-C"
arch=('x86_64' 'aarch64')
url="https://github.com/omakasui/asdcontrol"
license=('GPL2')
options=('!debug')
depends=('glibc' 'gcc-libs')
makedepends=('make' 'gcc')
source=(
  "$pkgname-$pkgver.tar.gz::https://github.com/omakasui/asdcontrol/archive/refs/tags/v$pkgver.tar.gz"
  'asdcontrol.sudoers'
)
sha256sums=(
  '3112a6d5fc51a204c96ef9d27187577c6efc80b952e37a77969efbd0124e81d3'
  '70d6838f91cf4b5e51974b9b62b141924cec844a2e60de79607839584ede847f'
)

build() {
  cd "$srcdir/asdcontrol-$pkgver"
  make
}

package() {
  cd "$srcdir/asdcontrol-$pkgver"

  install -Dm755 asdcontrol "$pkgdir/usr/bin/asdcontrol"
  install -dm750 "$pkgdir/etc/sudoers.d"
  install -m440 "$srcdir/asdcontrol.sudoers" "$pkgdir/etc/sudoers.d/50-asdcontrol"
}
