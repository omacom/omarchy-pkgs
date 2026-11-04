# Pinta for Arch Linux ARM. The official repositories do not supply its
# .NET dependencies on ARM; use the dotnet-core-bin split package family.

pkgname=pinta
pkgver=3.1.2
pkgrel=1
pkgdesc="Drawing/editing program modeled after Paint.NET. It's goal is to provide a simplified alternative to GIMP for casual users"

arch=('aarch64')
license=('MIT')
url="https://pinta-project.com"

makedepends=('pkgconf' 'intltool' 'dotnet-sdk-bin')
depends=('dotnet-runtime-bin' 'dotnet-host-bin' 'libadwaita' 'hicolor-icon-theme' 'webp-pixbuf-loader')

conflicts=($pkgname-git)

source=("https://github.com/PintaProject/Pinta/releases/download/${pkgver}/pinta-${pkgver}.tar.gz")
sha256sums=('27f55a026b51f6f18197e6bcfdd7c79544e41529d166daf6c93a1117e9ed45f0')

build() {
  cd "${srcdir}/pinta-${pkgver}"
  ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var
  make PINTA_BUILD_OPTS='--configuration Release -p:BuildTranslations=true -p:RuntimeIdentifier=linux-arm64'
}

package() {
  cd "${srcdir}/pinta-${pkgver}"

  make DESTDIR="${pkgdir}" install

  install -Dm644 -t "${pkgdir}/usr/share/doc/${pkgname}/" readme.md
  install -Dm644 -t "${pkgdir}/usr/share/licenses/${pkgname}/" license-*.txt
}
