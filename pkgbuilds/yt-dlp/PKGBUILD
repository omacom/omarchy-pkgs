# Maintainer: Antonio Rojas <arojas@archlinux.org>
# Contributor: Stefan Tatschner <stefan@rumpelsepp.org>
# Contributor: katt <magunasu.b97@gmail.com>

pkgname=yt-dlp
pkgver=2026.08.19
pkgrel=1
pkgdesc='A youtube-dl fork with additional features and fixes'
arch=(any)
url='https://github.com/yt-dlp/yt-dlp'
license=(Unlicense)
depends=(python
         python-certifi
         python-requests
         python-urllib3
         yt-dlp-ejs)
makedepends=(python-build
             python-hatchling
             python-installer)
checkdepends=(python-pytest)
optdepends=('ffmpeg: for video post-processing'
            'rtmpdump: for rtmp streams support'
            'atomicparsley: for embedding thumbnails into m4a files'
            'aria2: for using aria2 as external downloader'
            'python-curl_cffi: support for impersonating browser requests'
            'python-mutagen: for embedding thumbnail in certain formats'
            'python-pycryptodome: for decrypting AES-128 HLS streams and various other data'
            'python-pycryptodomex: for decrypting AES-128 HLS streams and various other data'
            'python-websockets: for downloading over websocket'
            'python-brotli: brotli content encoding support'
            'python-brotlicffi: brotli content encoding support'
            'python-xattr: for writing xattr metadata'
            'python-pyxattr: for writing xattr metadata (alternative option)'
            'python-secretstorage: For -cookies-from-browser to access the GNOME keyring while decrypting cookies of Chromium-based browsers')
source=($pkgname-$pkgver.tar.gz::https://github.com/yt-dlp/yt-dlp/releases/download/$pkgver/yt-dlp.tar.gz)
sha256sums=('072aad4f2a7604e92155f61a275a4752dc64046c8f6d90df3710525d94cd37c1')

build() {
  cd $pkgname
  python -m build --wheel --no-isolation
}

check() {
  cd $pkgname
  pytest -v -m "not download"
}

package() {
  cd $pkgname
  python -m installer --destdir="$pkgdir" dist/*.whl
}
