#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

fail() {
  echo "not ok - $1" >&2
  exit 1
}

source "$package_dir/PKGBUILD"

[[ $_commit =~ ^[0-9a-f]{40}$ ]] ||
  fail "iptsd builds from a pinned 40-hex commit"
[[ ${source[0]} == *"#commit=${_commit}" ]] ||
  fail "the source is fetched at the pinned commit"
grep -q -- '--wrap-mode=nofallback' "$package_dir/PKGBUILD" ||
  fail "iptsd links against Arch libraries instead of bundled copies"
grep -q -- '-Ddebug_tools= ' "$package_dir/PKGBUILD" ||
  fail "the SDL and Cairo debug tools are not built"
for dependency in fmt libinih spdlog; do
  [[ " ${depends[*]} " == *" $dependency "* ]] || fail "iptsd depends on $dependency at runtime"
done
for dependency in cli11 cmake eigen microsoft-gsl; do
  [[ " ${makedepends[*]} " == *" $dependency "* ]] || fail "iptsd builds with $dependency"
done

[[ " ${arch[*]} " == " aarch64 " ]] ||
  fail "iptsd is aarch64-only, leaving Intel Surfaces to the linux-surface package"

grep -q "sed -i 's/ACTION==\"add\"/ACTION!=\"remove\"/'" "$package_dir/PKGBUILD" ||
  fail "a udev change event, such as pacman's rule reload, keeps iptsd running"

for model in romulus15 romulus13; do
  grep -qx "ConditionFirmware=|device-tree-compatible(microsoft,$model)" \
    "$package_dir/iptsd-romulus15-resume.service" ||
    fail "the resume restart runs on the Surface Laptop 7 ($model)"
  grep -qx "ConditionFirmware=|device-tree-compatible(microsoft,$model)" \
    "$package_dir/iptsd-romulus15-boot.service" ||
    fail "the boot-time start runs on the Surface Laptop 7 ($model)"
done
(( $(grep -c '^ConditionFirmware=' "$package_dir/iptsd-romulus15-resume.service") == 2 )) ||
  fail "the resume restart stays off every machine but the Surface Laptop 7"
(( $(grep -c '^ConditionFirmware=' "$package_dir/iptsd-romulus15-boot.service") == 2 )) ||
  fail "the boot-time start stays off every machine but the Surface Laptop 7"
grep -q 'suspend.target.wants/iptsd-romulus15-resume.service' "$package_dir/PKGBUILD" ||
  fail "the resume restart is enabled by the package"

grep -q 'multi-user.target.wants/iptsd-romulus15-boot.service' "$package_dir/PKGBUILD" ||
  fail "the boot-time start is enabled by the package"
grep -qx 'Type=exec' "$package_dir/iptsd-romulus15-boot.service" ||
  fail "the boot-time start doesn't hold up multi-user.target"
bash -n "$package_dir/iptsd-romulus15-boot" ||
  fail "the boot-time start script has valid syntax"

grep -qx 'Product = 0x0C77' "$package_dir/surface-laptop-7-touchpad.conf" &&
  grep -qx 'OrientationThresholdMax = 180' "$package_dir/surface-laptop-7-touchpad.conf" ||
  fail "the Surface Laptop 7 touchpad keeps contacts whose orientation flips"
grep -q 'install -Dm644 surface-laptop-7-touchpad.conf -t "$pkgdir/usr/share/iptsd"' "$package_dir/PKGBUILD" ||
  fail "the touchpad config is installed"

grep -q 'ForceButton = 0x96' "$package_dir/0001-ipts-Handle-the-button-report-of-force-touchpads.patch" ||
  fail "the force touchpad's button report is read"
grep -q 'patch -d iptsd -Np1 -i ../0001-ipts-Handle-the-button-report-of-force-touchpads.patch' "$package_dir/PKGBUILD" ||
  fail "the force touchpad patch is applied"

grep -q 'patch -d iptsd -Np1 -i ../0002-contacts-Add-a-position-slop-for-new-contacts.patch' "$package_dir/PKGBUILD" ||
  fail "the position slop patch is applied"
grep -q '^Product = 0x0C6F$' "$package_dir/surface-laptop-7-15.conf" ||
  fail "the position slop is limited to the Surface Laptop 7 15\" touchscreen"
grep -q '^PositionSlop = 0.25$' "$package_dir/surface-laptop-7-15.conf" ||
  fail "a tap on the Surface Laptop 7 15\" touchscreen stays in place"
grep -q '^  ./test-position-slop$' "$package_dir/PKGBUILD" ||
  fail "the position slop is checked against contacts that land, move and lift"
grep -q 'install -Dm644 surface-laptop-7-15.conf surface-laptop-7-13.conf -t "$pkgdir/usr/share/iptsd"' "$package_dir/PKGBUILD" ||
  fail "the Surface Laptop 7 15\" and 13.8\" presets are installed where iptsd reads presets"
grep -qx 'Product = 0x0C6E' "$package_dir/surface-laptop-7-13.conf" &&
  grep -qx 'PositionSlop = 0.25' "$package_dir/surface-laptop-7-13.conf" ||
  fail "the position slop covers the Surface Laptop 7 13.8\" touchscreen"

echo "ok - iptsd builds pinned upstream source against Arch libraries"
