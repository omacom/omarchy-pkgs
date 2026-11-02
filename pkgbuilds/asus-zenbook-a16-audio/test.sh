#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

source "$package_dir/PKGBUILD"
[[ " ${arch[*]} " == " aarch64 " && " ${groups[*]} " == *" omarchy-platform-qualcomm "* ]] ||
  fail "the package is tagged Qualcomm-only for aarch64"

pkgdir="$scratch/pkg"
(cd "$package_dir" && package)

# The topology name must resolve to the CRD topology it stands in for.
root="$scratch/root"
mkdir -p "$root/usr/lib/firmware/qcom/glymur"
touch "$root/usr/lib/firmware/qcom/glymur/GLYMUR-CRD-tplg.bin"
cp -a "$pkgdir/usr" "$root/"

tplg="$root/usr/lib/firmware/qcom/glymur/GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin"
[[ $(readlink -f "$tplg") == "$root/usr/lib/firmware/qcom/glymur/GLYMUR-CRD-tplg.bin" ]] ||
  fail "the topology links to the CRD topology"

# The fixture above cannot notice linux-firmware-qcom renaming or dropping the
# CRD topology, so where that package is installed, check the link against the
# files it really ships.
if pacman -Qq linux-firmware-qcom &>/dev/null; then
  target=$(readlink "$pkgdir/usr/lib/firmware/qcom/glymur/GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin")
  pacman -Qlq linux-firmware-qcom | grep -qxF "/usr/lib/firmware/qcom/glymur/$target" ||
    fail "linux-firmware-qcom ships the topology the link names ($target)"
fi

# The UCM profile restates the CRD profile and sets the WSA digital volumes on
# every boot.
ucm="$pkgdir/usr/share/alsa/ucm2/conf.d/glymur/ASUSTeKCOMPUTERINC.-ZenbookA16UX3607OA-1.0-UX3607OA.conf"
[[ -f $ucm && ! -L $ucm ]] || fail "the UCM profile is a file"
crd=/usr/share/alsa/ucm2/Qualcomm/glymur/GLYMUR-CRD.conf
if [[ -f $crd ]]; then
  while IFS= read -r line; do
    [[ -z ${line//[[:space:]]/} || $line == \#* ]] && continue
    grep -qxF -- "$line" "$ucm" || fail "the UCM profile restates the CRD profile: $line"
  done <"$crd"
fi
for c in "WSA WSA_RX0" "WSA WSA_RX1" "WSA2 WSA_RX0" "WSA2 WSA_RX1"; do
  sed -n '/^FixedBootSequence \[/,/^\]/p' "$ucm" | grep -qF "cset \"name='$c Digital Volume' 100%\"" ||
    fail "the UCM profile sets $c Digital Volume to its ceiling on every boot"
done

rules="$pkgdir/usr/lib/udev/rules.d/60-asus-zenbook-a16-soundwire.rules"
[[ -f $rules ]] || fail "the SoundWire udev rule is installed"
grep -q 'ATTR{\[dmi/id\]board_name}=="UX3607OA"' "$rules" ||
  fail "the SoundWire udev rule only applies to the Zenbook A16"
grep -q 'KERNEL=="6c80000.soundwire|6ca0000.soundwire"' "$rules" ||
  fail "the SoundWire udev rule covers both WSA controllers"
grep -q 'ATTR{power/control}="on"' "$rules" ||
  fail "the SoundWire udev rule keeps the controllers awake"
if command -v udevadm >/dev/null; then
  udevadm verify --no-style "$rules" >/dev/null 2>&1 || fail "the SoundWire udev rule parses"
fi

wp="$pkgdir/usr/share/wireplumber/wireplumber.conf.d/60-asus-zenbook-a16-soft-volume.conf"
[[ -f $wp ]] || fail "the WirePlumber soft-volume rule is installed"
grep -q 'api.alsa.card.longname = "ASUSTeKCOMPUTERINC.-ZenbookA16UX3607OA-1.0-UX3607OA"' "$wp" ||
  fail "the soft-volume rule only applies to the Zenbook A16's card"
grep -q 'api.alsa.soft-mixer = true' "$wp" || fail "the soft-volume rule switches to software volume"

echo "ok - asus-zenbook-a16-audio"
