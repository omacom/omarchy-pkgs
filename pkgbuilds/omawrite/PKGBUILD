# Maintainer: David Heinemeier Hansson <david@hey.com>

pkgname=omawrite
pkgver=0.7.0
pkgrel=1
pkgdesc='Dead-simple Markdown writing app built with Qt Quick'
arch=('x86_64' 'aarch64')
url='https://github.com/omacom/omawrite'
license=('MIT' 'OFL-1.1')
install='omawrite.install'
options=('!debug')
depends=(
  'hicolor-icon-theme'
  'qt6-base'
  'qt6-declarative'
  'xdg-desktop-portal'
)
makedepends=(
  'gcc'
  'make'
  'qt6-base'
  'qt6-declarative'
)
source=("$pkgname-$pkgver.tar.gz::https://github.com/omacom/omawrite/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('0c6b3f765352bc13cb5a31b90b18838f0831bd1e3999f885de810eaf07c8a105')

build() {
  cd "$srcdir/$pkgname-$pkgver"
  ./bin/build
}

package() {
  cd "$srcdir/$pkgname-$pkgver"

  install -Dm755 build/omawrite "$pkgdir/usr/bin/omawrite"
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  install -Dm644 fonts/OFL.txt "$pkgdir/usr/share/licenses/$pkgname/OFL.txt"
  install -Dm644 pkgbuild/omawrite.svg "$pkgdir/usr/share/icons/hicolor/scalable/apps/omawrite.svg"
  install -Dm644 pkgbuild/omawrite.desktop "$pkgdir/usr/share/applications/omawrite.desktop"
}
