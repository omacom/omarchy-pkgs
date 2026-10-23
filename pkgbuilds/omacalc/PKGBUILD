# Maintainer: David Heinemeier Hansson <david@hey.com>

pkgname=omacalc
pkgver=0.3.1
pkgrel=1
pkgdesc='Dead-simple calculator built with Qt Quick'
arch=('x86_64' 'aarch64')
url='https://github.com/omacom-io/omacalc'
license=('MIT' 'OFL-1.1')
install='omacalc.install'
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
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('0f329bac3812d5440bb00f97bad0e63fd166ea9dedc1809f339d7e1f325499ee')

build() {
  cd "$srcdir/$pkgname-$pkgver"
  ./bin/build
}

package() {
  cd "$srcdir/$pkgname-$pkgver"

  install -Dm755 build/omacalc "$pkgdir/usr/bin/omacalc"
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  install -Dm644 fonts/OFL.txt "$pkgdir/usr/share/licenses/$pkgname/OFL.txt"
  install -Dm644 pkgbuild/omacalc.svg "$pkgdir/usr/share/icons/hicolor/scalable/apps/omacalc.svg"
  install -Dm644 pkgbuild/omacalc.desktop "$pkgdir/usr/share/applications/omacalc.desktop"
}
