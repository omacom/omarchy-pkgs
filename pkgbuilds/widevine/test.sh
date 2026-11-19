#!/bin/bash
# widevine builds Google's CDM into the package, as asahi-alarm's recipe does,
# and its scriptlet puts the library at the paths Chromium and Firefox load,
# including over a library that 4.10.2891.0-2 or -3 fetched there unowned.
set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

source "$package_dir/PKGBUILD"

(( $(vercmp "$pkgver-$pkgrel" 4.10.2891.0-3) > 0 )) || fail "widevine upgrades the fetch-on-device 4.10.2891.0-3"
(( $(vercmp "$pkgver" 4.10.2891.0) >= 0 )) || fail "widevine keeps at least asahi-alarm's pkgver"
(( ${#source[@]} == ${#sha256sums[@]} )) || fail "every source has a checksum"
[[ ${source[0]} == "lacros-arm64.squashfs::$_lacros_url" && ${sha256sums[0]} == "$_lacros_sha256" ]] ||
  fail "the Lacros image is pinned to _lacros_sha256"
for i in "${!source[@]}"; do
  [[ ${source[i]} == *://* ]] && continue
  [[ $(sha256sum "$package_dir/${source[i]}" | cut -d' ' -f1) == "${sha256sums[i]}" ]] ||
    fail "${source[i]} matches its sha256sums entry"
done
[[ ! -e $package_dir/widevine-fetch ]] || fail "nothing asks the user to fetch the library"

# package(), with a stand-in for the patched library and the image's licence.
srcdir="$scratch/src"
pkgdir="$scratch/pkg"
mkdir -p "$srcdir/squashfs-root/WidevineCdm"
cp "$package_dir/LICENSE" "$srcdir/"
echo "patched cdm" > "$srcdir/libwidevinecdm.so"
echo "Google licence" > "$srcdir/squashfs-root/WidevineCdm/LICENSE"
(cd "$srcdir" && package)

cdm=/opt/WidevineCdm/chromium/_platform_specific/linux_arm64/libwidevinecdm.so
x64=/opt/WidevineCdm/chromium/_platform_specific/linux_x64/libwidevinecdm.so
gmp=/opt/WidevineCdm/firefox/gmp-widevinecdm/system-installed/libwidevinecdm.so
[[ $(cat "$pkgdir/usr/lib/widevine/libwidevinecdm.so") == "patched cdm" ]] || fail "the package ships the patched library"
for path in "$cdm" "$x64" "$gmp"; do
  [[ ! -e $pkgdir$path && ! -L $pkgdir$path ]] || fail "the package doesn't own $path, which -2/-3 left unowned"
done
[[ $(readlink "$pkgdir/usr/lib/chromium/WidevineCdm") == /opt/WidevineCdm/chromium ]] || fail "Chromium's WidevineCdm link"
grep -qF "\"version\": \"$pkgver\"" "$pkgdir/opt/WidevineCdm/chromium/manifest.json" || fail "the manifest names pkgver"
[[ -L $pkgdir/opt/WidevineCdm/firefox/gmp-widevinecdm/system-installed/manifest.json ]] || fail "Firefox's GMP manifest"
grep -qF 'media.gmp-widevinecdm.enabled", true' "$pkgdir/usr/lib/firefox/browser/defaults/preferences/widevine.js" || fail "Firefox prefs"
[[ -f $pkgdir/etc/profile.d/firefox_widevine.sh ]] || fail "Firefox's MOZ_GMP_PATH"
[[ -f $pkgdir/usr/share/licenses/widevine/LICENSE.widevine ]] || fail "Google's licence from the image"
[[ ! -e $pkgdir/usr/bin/widevine-fetch && ! -e $pkgdir/usr/lib/systemd ]] || fail "no fetch command or units"

# The scriptlet, on a stand-in root.
root="$scratch/root"
mkdir -p "$root"
cp -a "$pkgdir/." "$root/"
sed -e "s#/opt/WidevineCdm#$root/opt/WidevineCdm#g" -e "s#/usr/lib/widevine#$root/usr/lib/widevine#g" \
  -e "s#/var/lib/widevine#$root/var/lib/widevine#g" -e "s#/var/cache/widevine#$root/var/cache/widevine#g" \
  -e "s#/run/widevine#$root/run/widevine#g" -e 's#/run/systemd/system#/nonexistent#' \
  "$package_dir/widevine.install" > "$scratch/install"
! grep -qE '(^|[ "=])/(opt|var|run|usr/lib/widevine)/' "$scratch/install" || fail "the test copy still names a system path"
# shellcheck source=/dev/null
source "$scratch/install"

out=$(post_install)
[[ $(cat "$root$cdm") == "patched cdm" && -x $root$cdm ]] || fail "post_install installs the library"
[[ -f $root$x64 ]] || fail "post_install adds the x64 placeholder"
[[ $(readlink "$root$gmp") == ../../../chromium/_platform_specific/linux_arm64/libwidevinecdm.so && -e $root$gmp ]] ||
  fail "post_install links Firefox's GMP directory"
[[ $out == *bitmovin.com/demos/drm* ]] || fail "post_install says how to test playback"

# An upgrade from -3 over a library it fetched: replaced, and the fetch state removed.
echo "fetched cdm" > "$root$cdm"
mkdir -p "$root/var/lib/widevine" "$root/var/cache/widevine" "$root/run/widevine"
post_upgrade >/dev/null
[[ $(cat "$root$cdm") == "patched cdm" ]] || fail "post_upgrade replaces a fetched library"
[[ ! -e $root/var/lib/widevine && ! -e $root/var/cache/widevine && ! -e $root/run/widevine ]] ||
  fail "post_upgrade removes the fetch's state"

# Removal deletes what the scriptlet installed. pacman removes the owned files first.
rm -f "$root/usr/lib/widevine/libwidevinecdm.so" "$root/opt/WidevineCdm/chromium/manifest.json" \
  "$root/opt/WidevineCdm/firefox/gmp-widevinecdm/system-installed/manifest.json"
post_remove
[[ ! -e $root/opt/WidevineCdm && ! -L $root$gmp ]] || fail "post_remove leaves nothing under /opt/WidevineCdm"

echo "ok - widevine"
