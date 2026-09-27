#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

fail() {
  echo "not ok - $1" >&2
  exit 1
}

replaces=()
source "$package_dir/PKGBUILD"

[[ ${source[0]} == *"#tag=v$pkgver" ]] || fail "libcamera builds from its release tag"
(( $(ls "$package_dir"/000*.patch | wc -l) == 3 )) || fail "the IMX681 patch series is complete"
grep -q '"imx681"' "$package_dir/0001-libcamera-camera_sensor_properties-Add-IMX681.patch" ||
  fail "the sensor properties name the IMX681"
grep -q 'CameraSensorHelperImx681' "$package_dir/0002-libipa-camera_sensor_helper-add-imx681.patch" ||
  fail "the gain helper is registered for the IMX681"
grep -q 'src/ipa/simple/data/imx681.yaml' "$package_dir/0003-ipa-simple-Add-initial-IMX681-tuning-data.patch" ||
  fail "the simple IPA tuning file is added"
[[ " ${provides[*]} " == *" libcamera=$pkgver "* && " ${provides[*]} " == *" libcamera-ipa=$pkgver "* ]] ||
  fail "pipewire-libcamera and libcamera-tools can depend on this build"
[[ " ${conflicts[*]} " == *" libcamera "* ]] || fail "it conflicts with the distribution libcamera"
(( ${#replaces[@]} == 0 )) || fail "it never replaces the distribution libcamera on other machines"
grep -q -- '-D pipelines=simple,uvcvideo' "$package_dir/PKGBUILD" || fail "the simple and USB pipelines are built"
[[ " ${options[*]} " == *" !strip "* ]] ||
  fail "makepkg does not strip the signed IPA, which would make libcamera isolate it"
grep -q 'ipa-sign.sh' "$package_dir/PKGBUILD" || fail "the stripped IPA is re-signed"
for patch in "$package_dir"/000*.patch; do
  grep -q '^Signed-off-by: ' "$patch" || fail "$(basename "$patch") is signed off"
done

echo "ok - libcamera-surface-pro-11 carries the IMX681 series on its release tag"
