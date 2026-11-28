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
(cd "$package_dir" && package_asus-zenbook-a16-audio)

# linux-firmware-qcom ships the board's topology since 20261019-1.1, so this
# package must not: a file of its own at that path would conflict with it.
[[ ! -e $pkgdir/usr/lib/firmware && ! -L $pkgdir/usr/lib/firmware ]] ||
  fail "the package leaves the firmware to linux-firmware-qcom"
# The build installs the unversioned dependency; the built package must ask for
# the linux-firmware-qcom that ships the topology.
built_depends=$(cd "$package_dir" && package_asus-zenbook-a16-audio >/dev/null 2>&1; printf '%s\n' "${depends[@]}")
grep -qxF 'linux-firmware-qcom>=20261019-1.1' <<<"$built_depends" ||
  fail "the built package needs the linux-firmware-qcom that ships the topology"

# The UCM profile restates the CRD profile (except the HiFi include, which now
# points at the A16 HiFi) and sets the WSA digital volumes on every boot.
ucm="$pkgdir/usr/share/alsa/ucm2/conf.d/glymur/ASUSTeKCOMPUTERINC.-ZenbookA16UX3607OA-1.0-UX3607OA.conf"
[[ -f $ucm && ! -L $ucm ]] || fail "the UCM profile is a file"
hifi="$pkgdir/usr/share/alsa/ucm2/glymur/ZenbookA16-HiFi.conf"
[[ -f $hifi && ! -L $hifi ]] || fail "the A16 HiFi is a file"
grep -qF 'File "/glymur/ZenbookA16-HiFi.conf"' "$ucm" ||
  fail "the UCM profile uses the A16 HiFi"
grep -qF 'SectionDevice."HDMI0"' "$hifi" || fail "the A16 HiFi defines the HDMI0 device"
grep -qF 'SectionDevice."HDMI1"' "$hifi" || fail "the A16 HiFi defines the HDMI1 device"
grep -qF 'SectionDevice."HDMI2"' "$hifi" || fail "the A16 HiFi defines the HDMI2 device"
grep -qF 'JackControl "DP0 Jack"' "$hifi" || fail "the HDMI0 device uses the DP0 jack"
crd=/usr/share/alsa/ucm2/Qualcomm/glymur/GLYMUR-CRD.conf
if [[ -f $crd ]]; then
  while IFS= read -r line; do
    [[ -z ${line//[[:space:]]/} || $line == \#* ]] && continue
    [[ $line == *'File "/Qualcomm/glymur/HiFi.conf"' ]] && continue
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

wp_names="$pkgdir/usr/share/wireplumber/wireplumber.conf.d/60-asus-zenbook-a16-node-names.conf"
[[ -f $wp_names ]] || fail "the WirePlumber node-name rule is installed"
grep -q 'node.nick = "Speaker"' "$wp_names" || fail "the node-name rule names the speaker"
grep -q 'node.nick = "HDMI0 (USB-C)"' "$wp_names" || fail "the node-name rule names HDMI0"
grep -q 'node.nick = "HDMI1 (USB-C)"' "$wp_names" || fail "the node-name rule names HDMI1"
grep -q 'node.nick = "HDMI2 (onboard)"' "$wp_names" || fail "the node-name rule names HDMI2"
grep -q 'node.nick = "Microphone"' "$wp_names" || fail "the node-name rule names the microphone"

echo "ok - asus-zenbook-a16-audio"
