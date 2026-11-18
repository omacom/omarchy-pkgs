#!/bin/bash
# The package carries only our own bytes: no Google library or image, nothing
# fetched at build or install time, and a fetch that refuses to run in a chroot.
set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

source "$package_dir/PKGBUILD"
for item in "${source[@]}"; do
  [[ $item != *://* ]] || fail "widevine downloads nothing at build time ($item)"
done
[[ $(type -t build) != function && $(type -t prepare) != function ]] ||
  fail "widevine has no build or prepare step"
(( $(vercmp "$pkgver-$pkgrel" 4.10.2891.0-1) > 0 )) || fail "widevine upgrades asahi-alarm's 4.10.2891.0-1"
(( $(vercmp "$pkgver" 4.10.2891.0) >= 0 )) || fail "widevine keeps at least asahi-alarm's pkgver"

srcdir="$scratch/src"
pkgdir="$scratch/pkg"
mkdir -p "$srcdir"
for item in "${source[@]}"; do cp "$package_dir/$item" "$srcdir/"; done
(cd "$srcdir" && package)

while IFS= read -r -d '' path; do
  rel=${path#"$pkgdir"}
  [[ $rel != *.so* && $rel != *libwidevinecdm* ]] || fail "the package ships a path named for the library ($rel)"
  [[ $rel != *squash* ]] || fail "the package ships a path named for an image ($rel)"
done < <(find "$pkgdir" -mindepth 1 -print0)

while IFS= read -r -d '' file; do
  rel=${file#"$pkgdir"}
  magic=$(head -c4 "$file" | od -An -tx1 | tr -d ' \n')
  [[ $magic != 7f454c46 ]] || fail "the package ships an ELF binary ($rel)"
  [[ $magic != 68737173 ]] || fail "the package ships a squashfs image ($rel)"
  (( $(stat -c %s "$file") < 65536 )) || fail "the package ships a large file ($rel)"
done < <(find "$pkgdir" -type f -print0)

cdm=/opt/WidevineCdm/chromium/_platform_specific/linux_arm64/libwidevinecdm.so
[[ -d $pkgdir/opt/WidevineCdm/firefox/gmp-widevinecdm/system-installed ]] || fail "Firefox's GMP directory"
grep -qF 'ln -sfn ../../../chromium/_platform_specific/linux_arm64/libwidevinecdm.so "$GMP_LINK"' "$pkgdir/usr/bin/widevine-fetch" ||
  fail "the fetch links Firefox's GMP directory to the library"
[[ $(readlink "$pkgdir/usr/lib/chromium/WidevineCdm") == /opt/WidevineCdm/chromium ]] || fail "Chromium's WidevineCdm link"
[[ $(readlink "$pkgdir/usr/lib/systemd/system/timers.target.wants/widevine-fetch.timer") == ../widevine-fetch.timer ]] ||
  fail "the fetch timer is enabled by the package"
grep -qxF "LACROS_SHA256=$_lacros_sha256" "$pkgdir/usr/lib/widevine/source" || fail "the fetch is pinned to the recipe's sha256"
grep -qF "\"version\": \"$pkgver\"" "$pkgdir/opt/WidevineCdm/chromium/manifest.json" || fail "the manifest names pkgver"

# The scriptlet may start the timer, never fetch.
! grep -qE 'widevine-fetch( |$)|curl|unsquashfs|widevine_fixup' "$package_dir/widevine.install" ||
  fail "the install scriptlet fetches"
grep -qF "${cdm%/*/*}" "$package_dir/widevine.install" || fail "removal deletes the fetched library"

# Off a booted system (a container or an image build chroot) the fetch does nothing and succeeds.
out=$(bash "$pkgdir/usr/bin/widevine-fetch" 2>&1) || fail "widevine-fetch fails off a booted system: $out"
[[ $out == *"not on a booted system"* ]] || fail "widevine-fetch refuses off a booted system: $out"

echo "ok - widevine"
