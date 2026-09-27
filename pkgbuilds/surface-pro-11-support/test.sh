#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
extractor="$package_dir/extract-ath12k-board.py"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

# Build a board-2.bin container with two named records, in the ath12k layout.
python - "$scratch/board-2.bin" <<'EOF'
import struct, sys

def ie(kind, payload):
    return struct.pack("<II", kind, len(payload)) + payload + b"\0" * (-len(payload) % 4)

def board(name, data):
    return ie(0, ie(0, name.encode()) + ie(1, data))

content = b"QCA-ATH12K-BOARD\0mmm" + board("bus=pci,other", b"other-board-data") + board("bus=pci,wanted", b"wanted-board-data!")
open(sys.argv[1], "wb").write(content)
EOF

wanted_sha=$(printf 'wanted-board-data!' | sha256sum | cut -d' ' -f1)
python "$extractor" --expected-bytes 18 --expected-sha256 "$wanted_sha" \
  "$scratch/board-2.bin" "bus=pci,wanted" "$scratch/board.bin" ||
  fail "the named board record is extracted"
[[ $(<"$scratch/board.bin") == "wanted-board-data!" ]] ||
  fail "the extracted board record is unmodified"

if python "$extractor" --expected-bytes 18 --expected-sha256 "$(printf x | sha256sum | cut -d' ' -f1)" \
  "$scratch/board-2.bin" "bus=pci,wanted" "$scratch/wrong.bin" 2>/dev/null; then
  fail "a record with an unexpected checksum is rejected"
fi
[[ ! -e $scratch/wrong.bin ]] || fail "a rejected record leaves no output"

if python "$extractor" --expected-bytes 16 --expected-sha256 "$wanted_sha" \
  "$scratch/board-2.bin" "bus=pci,missing" "$scratch/missing.bin" 2>/dev/null; then
  fail "a missing record is rejected"
fi

source "$package_dir/PKGBUILD"
[[ $_board_record == *"subsystem-device=3378,qmi-chip-id=2,qmi-board-id=255" ]] ||
  fail "the package selects the validated Surface Pro 11 board record"
[[ " ${options[*]} " == *" !strip "* ]] ||
  fail "the ELF board data is packaged without stripping"
[[ " ${arch[*]} " == " aarch64 " && " ${groups[*]} " == *" omarchy-platform-qualcomm "* ]] ||
  fail "the package is tagged Qualcomm-only for aarch64"
grep -q "^_audioreach_commit=d7a5e9d80ad18a7a6844eeb32cacbdeea0e7e677$" "$package_dir/PKGBUILD" ||
  fail "the topology builds from pinned AudioReach source"
grep -q 'File "/Qualcomm/x1e80100/Surface11-HiFi.conf"' "$package_dir/MICROSOFT-Surface-Pro-11.conf" ||
  fail "the card profile points at the shipped HiFi verb"

grep -Fq 'api.libcamera.path = "/base/soc@0/cci@ac15000/i2c-bus@0/camera@60"' "$package_dir/50-surface-pro-11-cameras.conf" ||
  fail "the infrared sensor is hidden from camera pickers"
! grep -q 'monitor.v4l2.rules' "$package_dir/50-surface-pro-11-cameras.conf" ||
  fail "V4L2 devices are not disabled; in WirePlumber 0.5 that stalls camera discovery"

# Every hook acts only on the Surface Pro 11 OLED.
printf 'microsoft,denali-oled\0microsoft,denali\0qcom,x1e80100\0' >"$scratch/denali"
printf 'lenovo,yoga-slim7x\0qcom,x1e80100\0' >"$scratch/other"

# Battery: after resume the thresholds already set are written back unchanged.
battery="$scratch/qcom-battmgr-bat"
mkdir -p "$battery"
charge_sleep() {
  SP11_CHARGE_LIMIT_SYSFS="$battery" SP11_CHARGE_LIMIT_COMPATIBLE="$scratch/$1" \
    bash "$package_dir/surface-pro-11-charge-limit-sleep" "${@:2}"
}
thresholds() {
  printf '%s\n' "$1" >"$battery/charge_control_start_threshold"
  printf '%s\n' "$2" >"$battery/charge_control_end_threshold"
}
thresholds 60 90
[[ $(charge_sleep denali post suspend) == *"restored start=60 end=90" ]] ||
  fail "a user-chosen charge window is written back as set after resume"
[[ $(<"$battery/charge_control_start_threshold") == 60 && $(<"$battery/charge_control_end_threshold") == 90 ]] ||
  fail "the charge window is never replaced"
thresholds 0 100
[[ -z $(charge_sleep denali post suspend) ]] || fail "with no charge limit set, nothing is written"
thresholds 60 90
[[ -z $(charge_sleep other post suspend) ]] || fail "the charge hook does nothing on other hardware"
[[ -z $(charge_sleep denali pre suspend) ]] || fail "the charge hook acts only after resume"
! grep -l 'charge' "$package_dir"/*.service >/dev/null 2>&1 ||
  fail "no boot-time service imposes a charge window"

echo "ok - surface-pro-11-support verifies its hardware setup"
