#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

fail() {
  echo "not ok - $1" >&2
  exit 1
}

# Relay drop-in
dropin="$package_dir/v4l2-relayd-bluechip.service.conf"
grep -qx 'ConditionFirmware=|device-tree-compatible(anduril,bluechip)' "$dropin" ||
  fail "the relay runs on the Anduril BlueChip"
(( $(grep -c '^ConditionFirmware=' "$dropin") == 1 )) || fail "the relay runs on no other machine"
grep -qx 'ConditionPathExists=/sys/firmware/devicetree/base/soc@0/cci@ac16000/i2c-bus@1/camera@10' "$dropin" ||
  fail "the relay only runs when the camera device tree node is present"
grep -qx 'DeviceAllow=char-dma_heap rw' "$dropin" || fail "the software ISP can allocate its buffers"
grep -qx 'Environment=LIBCAMERA_IPA_CONFIG_PATH=/usr/share/anduril-bluechip-support/libcamera/ipa' "$dropin" ||
  fail "the relay loads the package-private sensor tuning file"
grep -qx 'ExecStartPost=-+/usr/lib/anduril-bluechip-support/bluechip-camera-announce' "$dropin" ||
  fail "the relay announces capture readiness through the helper script"
! grep -q '^DeviceAllow=$' "$dropin" || fail "the relay keeps its own device list"

# Capture announcement helper
announce="$package_dir/bluechip-camera-announce"
sh -n "$announce" || fail "the camera announce helper has valid POSIX sh syntax"
! grep -q 'video50' "$announce" || fail "the camera announce helper discovers the loopback node by label"
grep -q 'grep -Flx "\$label"' "$announce" || fail "the camera announce helper matches CARD_LABEL literally"
grep -q 'ID_V4L_CAPABILITIES=.*:capture:' "$announce" ||
  fail "the camera announce helper skips redundant udev change events when already capture-ready"

# Relay pipeline config
relay="$package_dir/v4l2-relayd-bluechip.conf"
(
  source "$relay"
  [[ $VIDEOSRC == 'libcamerasrc camera-name=/base/soc@0/cci@ac16000/i2c-bus@1/camera@10 '* ]] ||
    fail "the relay opens the front camera by its device tree path"
  [[ $VIDEOSRC == *"width=${WIDTH},height=${HEIGHT}"* ]] || fail "the relay's source and output sizes agree"
  [[ $CARD_LABEL == 'Front Camera' ]] || fail "the relay fills the Front Camera device"
)
grep -q 'card_label="Front Camera"' "$package_dir/bluechip-camera-modprobe.conf" ||
  fail "the loopback device is the one the relay fills"
grep -q 'blackLevel: 4096' "$package_dir/ov08x40.yaml" || fail "the OV08X40 tuning gives the sensor's black level"
! grep -q 'Ccm:' "$package_dir/ov08x40.yaml" || fail "the OV08X40 tuning omits an unused CCM stage"

# WirePlumber rules & udev rule
cameras="$package_dir/50-bluechip-cameras.conf"
grep -q 'api.libcamera.path = "/base/soc@0/cci@ac16000/i2c-bus@1/camera@10"' "$cameras" ||
  fail "pickers hide the raw OV08X40 camera owned by the relay"
grep -q 'device.bus-path = "platform-acb6000.isp"' "$cameras" || fail "pickers hide the raw Glymur CAMSS nodes"
grep -qx 'SUBSYSTEM=="dma_heap", KERNEL=="system", TAG+="uaccess"' "$package_dir/70-bluechip-camera.rules" ||
  fail "udev grants uaccess on the system dma_heap"

# Camera guard
guard="$package_dir/bluechip-camera-guard"
bash -n "$guard" || fail "the camera guard has valid syntax"
grep -q '^unit=v4l2-relayd@bluechip.service$' "$guard" || fail "the guard watches the relay the package enables"
grep -q 'exp == system' "$guard" || fail "the guard counts leaked frame buffers on the system dma-buf heap"
grep -q 'relay_has_gpu' "$guard" || fail "the guard only restarts when the relay itself holds a leaked GPU context"
for error in 'Failed to start streaming' 'allocation failure'; do
  grep -qF "*\"$error\"*" "$guard" || fail "the guard restarts the relay on \"$error\""
done
unit="$package_dir/bluechip-camera-guard.service"
grep -qx 'ConditionFirmware=|device-tree-compatible(anduril,bluechip)' "$unit" ||
  fail "the camera guard runs on the Anduril BlueChip"
(( $(grep -c '^ConditionFirmware=' "$unit") == 1 )) || fail "the camera guard runs on no other machine"
grep -qx 'ConditionPathExists=/sys/firmware/devicetree/base/soc@0/cci@ac16000/i2c-bus@1/camera@10' "$unit" ||
  fail "the camera guard only runs when the camera device tree node is present"
grep -qx 'ExecStart=/usr/lib/anduril-bluechip-support/bluechip-camera-guard' "$unit" ||
  fail "the camera guard unit runs the installed script"
grep -qx 'ExecCondition=/usr/lib/anduril-bluechip-support/bluechip-camera-guard --needed' "$unit" ||
  fail "the camera guard stands down once libcamera 0.8.0 is installed"

echo "ok - Anduril BlueChip front camera relay, tuning, WirePlumber rules and guard"
