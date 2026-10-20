# Maintainer: David Heinemeier Hansson <david@hey.com>

pkgname=omacut
pkgver=0.7.2
pkgrel=1
pkgdesc='Dead-simple video length trimmer built with Qt Quick and ffmpeg'
arch=('x86_64' 'aarch64')
url='https://github.com/omacom/omacut'
license=('MIT')
install='omacut.install'
options=('!debug')
depends=(
  'ffmpeg'
  'hicolor-icon-theme'
  'qt6-base'
  'qt6-declarative'
  'qt6-multimedia'
  'xdg-desktop-portal'
)
makedepends=(
  'gcc'
  'make'
  'qt6-base'
  'qt6-declarative'
  'qt6-multimedia'
)
source=("$pkgname-$pkgver.tar.gz::https://github.com/omacom/omacut/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('93ea48761f516964c2ccfdc0a6cd00a5d36165b8a82588e63235a27ae355dc8c')

build() {
  cd "$srcdir/$pkgname-$pkgver"
  ./bin/build
}

package() {
  cd "$srcdir/$pkgname-$pkgver"

  install -Dm755 build/omacut "$pkgdir/usr/bin/omacut"
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  install -Dm644 pkgbuild/omacut.svg "$pkgdir/usr/share/icons/hicolor/scalable/apps/omacut.svg"
  install -Dm644 pkgbuild/omacut.desktop "$pkgdir/usr/share/applications/omacut.desktop"
}
