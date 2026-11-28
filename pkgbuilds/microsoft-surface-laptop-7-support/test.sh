#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
reader="$package_dir/surface-laptop-7-battery-info"
command="$package_dir/surface-laptop-7-battery"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

# A static-information response in SAM's layout (struct spwr_bix): 204 cycles,
# 63830 and 59780 mWh, with a serial number that must not be published.
python - "$scratch/bix" <<'EOF_PY'
import struct, sys

fields = [0, 63830, 59780, 1, 11380, 0, 0, 204, 1000, 0xFFFFFFFF, 0xFFFFFFFF, 1000, 1000, 10, 10]
bix = struct.pack("<B15I21s11s5s21s", 0, *fields, b"1271364010", b"SERIAL0042", b"LION", b"SMP")
open(sys.argv[1], "wb").write(bix)
open(sys.argv[1] + ".short", "wb").write(bix[:-1])
open(sys.argv[1] + ".mah", "wb").write(struct.pack("<B15I21s11s5s21s", 0, 1, *fields[1:], b"M", b"S", b"LION", b"SMP"))
EOF_PY

printf 'microsoft,romulus15\0qcom,x1e80100\0' >"$scratch/romulus15"
printf 'microsoft,romulus13\0qcom,x1e80100\0' >"$scratch/romulus13"
printf 'microsoft,denali\0qcom,x1e80100\0' >"$scratch/other-surface"

read_pack() {
  SL7_BATTERY_COMPATIBLE="$scratch/$1" SL7_BATTERY_RESPONSE="$scratch/$2" \
    SL7_BATTERY_OUT="$scratch/out/$3" python "$reader"
}

read_pack romulus15 bix battery || fail "a full response is read"
grep -qx 'cycle_count=204' "$scratch/out/battery" || fail "the cycle count is published"
grep -qx 'full_charge_capacity_mwh=59780' "$scratch/out/battery" || fail "capacities in mWh are published"
grep -qx 'maker=SMP' "$scratch/out/battery" || fail "the pack's maker is published"
! grep -q 'SERIAL0042' "$scratch/out/battery" || fail "the serial number is not published"

if read_pack romulus15 bix.short short 2>/dev/null; then
  fail "a response of the wrong length is rejected"
fi
[[ ! -e $scratch/out/short ]] || fail "a rejected response leaves no output"

read_pack romulus15 bix.mah mah || fail "a response in mAh is read"
! grep -q capacity "$scratch/out/mah" || fail "capacities in mAh are not published as mWh"

read_pack romulus13 bix romulus13-out || fail "the 13.8\" is read"
grep -qx 'cycle_count=204' "$scratch/out/romulus13-out" || fail "the 13.8\" cycle count is published"

read_pack other-surface bix other || fail "another laptop is left alone without an error"
[[ ! -e $scratch/out/other ]] || fail "nothing is read on another laptop"

for unit in service timer; do
  f="$package_dir/surface-laptop-7-battery-info.$unit"
  for model in romulus13 romulus15; do
    grep -qx "ConditionFirmware=|device-tree-compatible(microsoft,$model)" "$f" ||
      fail "the battery $unit runs on the Surface Laptop 7 ($model)"
  done
  (( $(grep -c '^ConditionFirmware=' "$f") == 2 )) || fail "the battery $unit runs on no other machine"
done

# The command, on a fixture battery at 66% with a 75/80 limit.
mkdir -p "$scratch/sysfs"
echo 59780000 >"$scratch/sysfs/energy_full"
echo 63830000 >"$scratch/sysfs/energy_full_design"
echo 39455000 >"$scratch/sysfs/energy_now"
echo Discharging >"$scratch/sysfs/status"
echo 75 >"$scratch/sysfs/charge_control_start_threshold"
echo 80 >"$scratch/sysfs/charge_control_end_threshold"

report=$(SL7_BATTERY_OUT="$scratch/out/battery" SL7_BATTERY_SYSFS="$scratch/sysfs" bash "$command")
[[ $report == *'Charge          66% (Discharging)'* ]] || fail "the charge is rounded from the energy counters"
[[ $report == *'Health          94% of design (59.78 of 63.83 Wh)'* ]] || fail "health is full charge against design"
[[ $report == *'Cycles          204'* ]] || fail "the cycle count comes from the controller's reading"

report=$(SL7_BATTERY_OUT="$scratch/out/none" SL7_BATTERY_SYSFS="$scratch/sysfs" bash "$command")
[[ $report == *'not read yet'* && $report == *'Charge limit    start below 75%, stop at 80%'* ]] ||
  fail "without a reading the command still reports what Linux knows"

# The front camera relay.
bash -n "$package_dir/surface-laptop-7-camera-gain" || fail "the camera gain helper has valid syntax"
mkdir -p "$scratch/v4l/v4l-subdev3" "$scratch/v4l/v4l-subdev7"
echo 'ov02c10 12-0036' >"$scratch/v4l/v4l-subdev3/name"
echo 'vd55g0 11-0010' >"$scratch/v4l/v4l-subdev7/name"
printf '#!/bin/sh\necho "$@" >>"%s/ctl.log"\n' "$scratch" >"$scratch/v4l2-ctl"
chmod +x "$scratch/v4l2-ctl"
SL7_CAMERA_SYSFS="$scratch/v4l" SL7_CAMERA_V4L2_CTL="$scratch/v4l2-ctl" sh "$package_dir/surface-laptop-7-camera-gain" 2048
[[ $(<"$scratch/ctl.log") == '-d /dev/v4l-subdev3 -c digital_gain=2048' ]] ||
  fail "only the OV02C10 gets the digital gain"
mkdir -p "$scratch/none"
SL7_CAMERA_SYSFS="$scratch/none" SL7_CAMERA_V4L2_CTL=false sh "$package_dir/surface-laptop-7-camera-gain" ||
  fail "the gain helper leaves a machine without the sensor alone"

dropin="$package_dir/v4l2-relayd-surface-laptop-7.service.conf"
for model in romulus13 romulus15; do
  grep -qx "ConditionFirmware=|device-tree-compatible(microsoft,$model)" "$dropin" ||
    fail "the relay runs on the Surface Laptop 7 ($model)"
done
(( $(grep -c '^ConditionFirmware=' "$dropin") == 2 )) || fail "the relay runs on no other machine"
grep -qx 'DeviceAllow=char-dma_heap rw' "$dropin" || fail "the software ISP can allocate its buffers"
! grep -q '^DeviceAllow=$' "$dropin" || fail "the relay keeps its own device list"

relay="$package_dir/v4l2-relayd-surface-laptop-7.conf"
(
  source "$relay"
  [[ $VIDEOSRC == 'libcamerasrc camera-name=/base/soc@0/cci@ac16000/i2c-bus@1/camera@36 '* ]] ||
    fail "the relay opens the front camera by its device tree path"
  [[ $VIDEOSRC == *"width=${WIDTH},height=${HEIGHT}"* ]] || fail "the relay's source and output sizes agree"
  [[ $CARD_LABEL == 'Front Camera' ]] || fail "the relay fills the Front Camera device"
)
grep -q 'card_label="Front Camera"' "$package_dir/surface-laptop-7-camera-modprobe.conf" ||
  fail "the loopback device is the one the relay fills"
grep -q 'blackLevel: 4096' "$package_dir/ov02c10.yaml" || fail "the tuning gives the sensor's black level"

cameras="$package_dir/50-surface-laptop-7-cameras.conf"
grep -q 'api.libcamera.path = "/base/soc@0/cci@ac16000/i2c-bus@1/camera@36"' "$cameras" ||
  fail "pickers don't offer the camera the relay owns"
grep -q 'device.bus-path = "platform-acb7000.isp"' "$cameras" || fail "pickers don't offer the raw camera nodes"

# The camera guard.
guard="$package_dir/surface-laptop-7-camera-guard"
bash -n "$guard" || fail "the camera guard has valid syntax"
grep -q '^unit=v4l2-relayd@surface-laptop-7.service$' "$guard" || fail "the guard watches the relay the package enables"
for error in 'Failed to start streaming' 'allocation failure'; do
  grep -qF "*\"$error\"*" "$guard" || fail "the guard restarts the relay on \"$error\""
done
unit="$package_dir/surface-laptop-7-camera-guard.service"
for model in romulus13 romulus15; do
  grep -qx "ConditionFirmware=|device-tree-compatible(microsoft,$model)" "$unit" ||
    fail "the camera guard runs on the Surface Laptop 7 ($model)"
done
(( $(grep -c '^ConditionFirmware=' "$unit") == 2 )) || fail "the camera guard runs on no other machine"
grep -qx 'ExecStart=/usr/lib/microsoft-surface-laptop-7-support/surface-laptop-7-camera-guard' "$unit" ||
  fail "the camera guard unit runs the installed script"
grep -qx 'ExecCondition=/usr/lib/microsoft-surface-laptop-7-support/surface-laptop-7-camera-guard --needed' "$unit" ||
  fail "the camera guard stands down once libcamera 0.8.0 is installed"

echo "ok - Surface Laptop 7 battery reader, command, front camera relay and its guard"
