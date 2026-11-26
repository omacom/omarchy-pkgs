#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

# Gain helper
bash -n "$package_dir/zenbook-a16-camera-gain" || fail "the camera gain helper has valid syntax"
mkdir -p "$scratch/v4l/v4l-subdev3" "$scratch/v4l/v4l-subdev7"
echo 'ov02c10 27-0036' >"$scratch/v4l/v4l-subdev3/name"
echo 'hm1092 24-0024' >"$scratch/v4l/v4l-subdev7/name"
printf '#!/bin/sh\necho "$@" >>"%s/ctl.log"\n' "$scratch" >"$scratch/v4l2-ctl"
chmod +x "$scratch/v4l2-ctl"
ZA16_CAMERA_SYSFS="$scratch/v4l" ZA16_CAMERA_V4L2_CTL="$scratch/v4l2-ctl" sh "$package_dir/zenbook-a16-camera-gain" 2048
[[ $(<"$scratch/ctl.log") == '-d /dev/v4l-subdev3 -c digital_gain=2048' ]] ||
  fail "only the OV02C10 gets the digital gain"
mkdir -p "$scratch/none"
ZA16_CAMERA_SYSFS="$scratch/none" ZA16_CAMERA_V4L2_CTL=false sh "$package_dir/zenbook-a16-camera-gain" ||
  fail "the gain helper leaves a machine without the sensor alone"

# Relay drop-in
dropin="$package_dir/v4l2-relayd-zenbook-a16.service.conf"
grep -qx 'ConditionFirmware=|device-tree-compatible(asus,zenbook-a16-ux3607oa)' "$dropin" ||
  fail "the relay runs on the ASUS Zenbook A16"
(( $(grep -c '^ConditionFirmware=' "$dropin") == 1 )) || fail "the relay runs on no other machine"
grep -qx 'DeviceAllow=char-dma_heap rw' "$dropin" || fail "the software ISP can allocate its buffers"
grep -qx 'Environment=LIBCAMERA_IPA_CONFIG_PATH=/usr/share/asus-zenbook-a16-support/libcamera/ipa' "$dropin" || fail "the relay loads the package-private sensor tuning files"
! grep -q '^DeviceAllow=$' "$dropin" || fail "the relay keeps its own device list"

# Relay pipeline config
relay="$package_dir/v4l2-relayd-zenbook-a16.conf"
(
  source "$relay"
  [[ $VIDEOSRC == 'libcamerasrc camera-name=/base/soc@0/cci@ac16000/i2c-bus@1/camera@36 '* ]] ||
    fail "the relay opens the front camera by its device tree path"
  [[ $VIDEOSRC == *"width=${WIDTH},height=${HEIGHT}"* ]] || fail "the relay's source and output sizes agree"
  [[ $CARD_LABEL == 'Front Camera' ]] || fail "the relay fills the Front Camera device"
)
grep -q 'card_label="Front Camera"' "$package_dir/zenbook-a16-camera-modprobe.conf" ||
  fail "the loopback device is the one the relay fills"
grep -q 'blackLevel: 4096' "$package_dir/ov02c10.yaml" || fail "the OV02C10 tuning gives the sensor's black level"
grep -q 'blackLevel: 2048' "$package_dir/hm1092.yaml" || fail "the HM1092 tuning gives the sensor's black level"

# WirePlumber rules
cameras="$package_dir/50-zenbook-a16-cameras.conf"
grep -q 'api.libcamera.path = "/base/soc@0/cci@ac15000/i2c-bus@0/camera@24"' "$cameras" ||
  fail "pickers hide the HM1092 IR camera"
grep -q 'api.libcamera.path = "/base/soc@0/cci@ac16000/i2c-bus@1/camera@36"' "$cameras" ||
  fail "pickers hide the raw OV02C10 camera owned by the relay"
grep -q 'device.bus-path = "platform-acb6000.isp"' "$cameras" || fail "pickers hide the raw Glymur CAMSS nodes"

# Camera guard
guard="$package_dir/zenbook-a16-camera-guard"
bash -n "$guard" || fail "the camera guard has valid syntax"
grep -q '^unit=v4l2-relayd@zenbook-a16.service$' "$guard" || fail "the guard watches the relay the package enables"
for error in 'Failed to start streaming' 'allocation failure'; do
  grep -qF "*\"$error\"*" "$guard" || fail "the guard restarts the relay on \"$error\""
done
unit="$package_dir/zenbook-a16-camera-guard.service"
grep -qx 'ConditionFirmware=|device-tree-compatible(asus,zenbook-a16-ux3607oa)' "$unit" ||
  fail "the camera guard runs on the ASUS Zenbook A16"
(( $(grep -c '^ConditionFirmware=' "$unit") == 1 )) || fail "the camera guard runs on no other machine"
grep -qx 'ExecStart=/usr/lib/asus-zenbook-a16-support/zenbook-a16-camera-guard' "$unit" ||
  fail "the camera guard unit runs the installed script"
grep -qx 'ExecCondition=/usr/lib/asus-zenbook-a16-support/zenbook-a16-camera-guard --needed' "$unit" ||
  fail "the camera guard stands down once libcamera 0.8.0 is installed"

# Power management udev rules
power_rules="$package_dir/90-asus-zenbook-a16-power.rules"
grep -qx 'ATTR{\[dmi/id\]board_name}!="UX3607OA", GOTO="zenbook_a16_power_end"' "$power_rules" ||
  fail "the power rules are gated to the ASUS Zenbook A16"
grep -q 'KERNEL=="ddr|ddr-qos|llcc"' "$power_rules" ||
  fail "the power rules stop CPUCP memlat polling on older kernels"
grep -q 'DRIVER=="dwc3-qcom"' "$power_rules" ||
  fail "the power rules enable runtime PM on dwc3-qcom"
grep -q 'ATTR{idVendor}=="0bda", ATTR{idProduct}=="0329"' "$power_rules" ||
  fail "the power rules enable autosuspend on the Realtek SD reader"

echo "ok - ASUS Zenbook A16 front camera relay, tuning, WirePlumber rules, guard and power rules"
