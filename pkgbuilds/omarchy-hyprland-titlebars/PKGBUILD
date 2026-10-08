# Maintainer: Ryan Hughes <ryan@heyoodle.com>

pkgname=omarchy-hyprland-titlebars
pkgver=0.1.0
pkgrel=1
pkgdesc="Titlebars and edge snapping for Omarchy's floating workspaces"
arch=('x86_64' 'aarch64')
url='https://github.com/omacom/omarchy'
license=('BSD-3-Clause' 'MIT')
# A Hyprland plugin only loads into the exact Hyprland build it was compiled
# against. rebuild_on in .omarchy/package.json rebuilds it with every Hyprland.
depends=('hyprland=0.56.2' 'glibc' 'libgcc' 'libstdc++' 'hyprlang' 'hyprutils')
makedepends=('cmake' 'pkgconf')
options=('!lto' '!debug')
source=('CMakeLists.txt'
        'main.cpp'
        'barDeco.cpp'
        'barDeco.hpp'
        'BarPassElement.cpp'
        'BarPassElement.hpp'
        'edgeSnap.cpp'
        'edgeSnap.hpp'
        'globals.hpp'
        'LICENSE'
        'LICENSE.MIT')
sha256sums=('27a292b1b037210774d785a8db17d0e77aceba529a9946b7b555bd6333b9b8e8'
            'aa6e0c8cb22dc4d26516fa64aac81d1e493cf7a9b99d7a8bd78b82d61b2f2e89'
            '2d9ab463efa263881c23110f9550b10694366e508418bfe06700dc9e18b31579'
            'dbdd56902558b36f7e7d01f7b9884530a93f7dda411a2b360acf69255a42c8f2'
            'e0074f71d8bbb3ae0a24a91a4647c4d0da6ab8c5effa0dce2b5a1bb8c85d085c'
            'dffbf8ddc768fd111b2a41697fe6547e954c46edc16750913c789d8daa8690cc'
            'a2b70dd8fc9974a9fca2f4a7db575d14c2c6802c154e4606a3c9e06c1b25a4e6'
            '2ebf96f7e7508e4485d706c99c186d6fabf14ba5ceb7349fbc3d72529904424e'
            '831147435d58b3071ad26fd756f9755eaf461793d664ea3cb049270b38228993'
            '3a1d080d85ce1d722b3bd84d87b74dd2332ba7b68a40a28a7126a86cfca6502a'
            '717ba1949502290f8e47688ae2e323acd06c8ca47aec9f7596b15f678c1af4a2')

build() {
  cmake -S "$srcdir" -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr
  cmake --build build
}

package() {
  DESTDIR="$pkgdir" cmake --install build
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  install -Dm644 LICENSE.MIT "$pkgdir/usr/share/licenses/$pkgname/LICENSE.MIT"
}
