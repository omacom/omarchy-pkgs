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
if command -v udevadm >/dev/null 2>&1; then
  udevadm verify --no-style "$power_rules" >/dev/null ||
    fail "the power rules pass udevadm verify"
fi
grep -qx 'ATTR{\[dmi/id\]board_name}=="UX3607OA", GOTO="zenbook_a16_power_start"' "$power_rules" ||
  fail "the power rules use a positive DMI guard for the ASUS Zenbook A16"
grep -qx 'GOTO="zenbook_a16_power_end"' "$power_rules" ||
  fail "the power rules skip non-matching machines"
awk '
  /\\$/ { sub(/\\$/, ""); buf = buf $0; next }
  { print buf $0; buf = "" }
' "$power_rules" >"$scratch/power.rules"
grep -q 'SUBSYSTEM=="devfreq", KERNEL=="ddr|ddr-qos|llcc",.*ATTR{polling_interval}="0"' "$scratch/power.rules" ||
  fail "the devfreq rule sets polling_interval=0"
grep -q 'DRIVER=="dwc3-qcom",.*ATTR{power/control}="auto", ATTR{power/autosuspend_delay_ms}="200"' "$scratch/power.rules" ||
  fail "the dwc3-qcom rule enables autosuspend with 200 ms delay"
grep -q 'DRIVER=="xhci-hcd",.*ATTR{power/control}="auto"' "$scratch/power.rules" ||
  fail "the xhci-hcd rule enables runtime PM"
grep -q 'DRIVER=="qcom-qmp-combo-phy|qcom-qmp-usb-phy",.*ATTR{power/control}="auto"' "$scratch/power.rules" ||
  fail "the QMP PHY rule enables runtime PM"
grep -q 'SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="0329",.*ATTR{power/control}="auto", ATTR{power/autosuspend_delay_ms}="200"' "$scratch/power.rules" ||
  fail "the Realtek USB rule enables autosuspend with 200 ms delay"
grep -q 'SUBSYSTEM=="scsi", ENV{DEVTYPE}=="scsi_device",.*ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="0329",.*ATTR{power/control}="auto", ATTR{power/autosuspend_delay_ms}="200"' "$scratch/power.rules" ||
  fail "the Realtek SCSI rule scopes to scsi_device and enables autosuspend"
grep -q 'SUBSYSTEM=="block", ENV{DEVTYPE}=="disk",.*ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="0329",.*ATTR{events_poll_msecs}="15000"' "$scratch/power.rules" ||
  fail "the Realtek block rule scopes to disk and sets events_poll_msecs=15000"
grep -qx 'TEST=="/run/archiso/bootmnt", GOTO="zenbook_a16_power_usb_end"' "$power_rules" ||
  fail "the power rules skip USB runtime PM on live/Try ISO sessions"
grep -qx 'LABEL="zenbook_a16_power_usb_end"' "$power_rules" ||
  fail "the power rules define zenbook_a16_power_usb_end"
awk '
  /^TEST=="\/run\/archiso\/bootmnt", GOTO="zenbook_a16_power_usb_end"$/ { in_usb = 1; next }
  /^LABEL="zenbook_a16_power_usb_end"$/ { in_usb = 0; seen_end = 1; next }
  in_usb && /DRIVER=="dwc3-qcom"/ { dwc3 = 1 }
  in_usb && /DRIVER=="xhci-hcd"/ { xhci = 1 }
  in_usb && /DRIVER=="qcom-qmp-combo-phy\|qcom-qmp-usb-phy"/ { phy = 1 }
  in_usb && /SUBSYSTEM=="usb", ATTR\{idVendor\}=="0bda", ATTR\{idProduct\}=="0329"/ { usb_reader = 1 }
  in_usb && /SUBSYSTEM=="scsi", ENV\{DEVTYPE\}=="scsi_device",.*ATTRS\{idVendor\}=="0bda", ATTRS\{idProduct\}=="0329"/ { scsi_reader = 1 }
  in_usb && /SUBSYSTEM=="block", ENV\{DEVTYPE\}=="disk",.*ATTRS\{idVendor\}=="0bda", ATTRS\{idProduct\}=="0329"/ { block_reader = 1 }
  seen_end && !in_usb && /KERNEL=="0004:00:00\.0\|0004:01:00\.0"/ { wifi_after = 1 }
  END { exit !(dwc3 && xhci && phy && usb_reader && scsi_reader && block_reader && wifi_after) }
' "$scratch/power.rules" ||
  fail "the USB and SD reader runtime PM rules sit inside the live-medium skip and Wi-Fi wakeup stays after it"
grep -q 'SUBSYSTEM=="pci", KERNEL=="0004:00:00.0|0004:01:00.0",.*ATTR{power/wakeup}="disabled"' "$scratch/power.rules" ||
  fail "the PCIe4 Wi-Fi root port and endpoint rule disables wakeup"
awk '
  /^LABEL="zenbook_a16_power_start"$/ { inside = 1; next }
  /^LABEL="zenbook_a16_power_end"$/ { inside = 0; next }
  inside && /KERNEL=="0004:00:00\.0\|0004:01:00\.0"/ { found = 1 }
  END { exit !found }
' "$scratch/power.rules" ||
  fail "the PCIe4 Wi-Fi wakeup rule sits inside the DMI guard"

# Sleep config
sleep_conf="$package_dir/60-zenbook-a16-sleep.conf"
grep -qx 'MemorySleepMode=s2idle' "$sleep_conf" ||
  fail "the sleep config selects s2idle"

# Sleep hook
sleep_hook="$package_dir/zenbook-a16-sleep"
bash -n "$sleep_hook" || fail "the sleep hook has valid syntax"

make_sleep_fixture() {
  local dir=$1 board=$2 bt0=$3 bt1=${4:-} sdw1_ctrl=${5:-on} sdw0_status=${6:-suspended}
  mkdir -p \
    "$dir/sys/class/dmi/id" \
    "$dir/sys/bus/pci/devices/0004:00:00.0/power" \
    "$dir/sys/bus/pci/devices/0004:01:00.0/power" \
    "$dir/sys/bus/platform/devices/6c80000.soundwire/power" \
    "$dir/sys/bus/platform/devices/6ca0000.soundwire/power" \
    "$dir/sys/bus/platform/devices/a400000.usb/power" \
    "$dir/sys/bus/platform/devices/a600000.usb/power" \
    "$dir/sys/bus/platform/devices/a800000.usb/power" \
    "$dir/run"
  printf '%s\n' "$board" >"$dir/sys/class/dmi/id/board_name"
  printf 'enabled\n' >"$dir/sys/bus/pci/devices/0004:00:00.0/power/wakeup"
  printf 'enabled\n' >"$dir/sys/bus/pci/devices/0004:01:00.0/power/wakeup"
  printf 'on\n' >"$dir/sys/bus/platform/devices/6c80000.soundwire/power/control"
  printf '%s\n' "$sdw0_status" >"$dir/sys/bus/platform/devices/6c80000.soundwire/power/runtime_status"
  printf '%s\n' "$sdw1_ctrl" >"$dir/sys/bus/platform/devices/6ca0000.soundwire/power/control"
  printf 'suspended\n' >"$dir/sys/bus/platform/devices/6ca0000.soundwire/power/runtime_status"
  printf 'enabled\n' >"$dir/sys/bus/platform/devices/a400000.usb/power/wakeup"
  printf 'disabled\n' >"$dir/sys/bus/platform/devices/a600000.usb/power/wakeup"
  printf 'enabled\n' >"$dir/sys/bus/platform/devices/a800000.usb/power/wakeup"
  printf '%s\n' "$bt0" >"$dir/bt_0"
  [[ -n $bt1 ]] && printf '%s\n' "$bt1" >"$dir/bt_1"
  cat >"$dir/rfkill" <<EOF
#!/bin/bash
if [[ \${1:-} == "-n" ]]; then
  echo "0 bluetooth \$(<"$dir/bt_0")"
  [[ -f "$dir/bt_1" ]] && echo "1 bluetooth \$(<"$dir/bt_1")"
  echo "2 wlan unblocked"
elif [[ \${1:-} == "block" ]]; then
  echo "blocked" >"$dir/bt_\$2"
  echo "block \$2" >>"$dir/rfkill.log"
elif [[ \${1:-} == "unblock" ]]; then
  echo "unblocked" >"$dir/bt_\$2"
  echo "unblock \$2" >>"$dir/rfkill.log"
fi
EOF
  chmod +x "$dir/rfkill"
}

run_sleep_hook() {
  local dir=$1
  shift
  ZA16_SLEEP_SYSFS="$dir/sys" \
    ZA16_SLEEP_RUN_DIR="$dir/run" \
    ZA16_SLEEP_RFKILL="$dir/rfkill" \
    ZA16_SLEEP_SDW_WAIT_MS=30 \
    ZA16_SLEEP_SDW_POLL_MS=10 \
    ZA16_SLEEP_BT_SETTLE=0 \
    bash "$sleep_hook" "$@"
}

# UX3607OA pre/post suspend with mixed BT adapters (0 unblocked, 1 blocked)
# and mixed SoundWire controls (6c80000 on, 6ca0000 auto)
f_a16="$scratch/sleep-a16"
make_sleep_fixture "$f_a16" UX3607OA unblocked blocked auto suspended
run_sleep_hook "$f_a16" pre suspend
[[ $(<"$f_a16/sys/bus/pci/devices/0004:00:00.0/power/wakeup") == "disabled" ]] ||
  fail "pre suspend disables PCIe4 Wi-Fi root port wakeup"
[[ $(<"$f_a16/sys/bus/pci/devices/0004:01:00.0/power/wakeup") == "disabled" ]] ||
  fail "pre suspend disables PCIe4 Wi-Fi endpoint wakeup"
[[ $(<"$f_a16/sys/bus/platform/devices/6c80000.soundwire/power/control") == "auto" ]] ||
  fail "pre suspend sets 6c80000.soundwire to auto"
[[ $(<"$f_a16/sys/bus/platform/devices/6ca0000.soundwire/power/control") == "auto" ]] ||
  fail "pre suspend keeps 6ca0000.soundwire auto"
[[ $(<"$f_a16/sys/bus/platform/devices/a400000.usb/power/wakeup") == "disabled" ]] ||
  fail "pre suspend disables a400000.usb wakeup"
[[ $(<"$f_a16/sys/bus/platform/devices/a600000.usb/power/wakeup") == "disabled" ]] ||
  fail "pre suspend keeps a600000.usb wakeup disabled"
[[ $(<"$f_a16/sys/bus/platform/devices/a800000.usb/power/wakeup") == "disabled" ]] ||
  fail "pre suspend disables a800000.usb wakeup"
[[ $(<"$f_a16/bt_0") == "blocked" && $(<"$f_a16/bt_1") == "blocked" ]] ||
  fail "pre suspend soft-blocks unblocked Bluetooth adapter 0 while leaving adapter 1 blocked"

run_sleep_hook "$f_a16" post suspend
[[ $(<"$f_a16/sys/bus/pci/devices/0004:00:00.0/power/wakeup") == "disabled" ]] ||
  fail "post resume keeps PCIe4 Wi-Fi root port wakeup disabled"
[[ $(<"$f_a16/sys/bus/pci/devices/0004:01:00.0/power/wakeup") == "disabled" ]] ||
  fail "post resume keeps PCIe4 Wi-Fi endpoint wakeup disabled"
[[ $(<"$f_a16/sys/bus/platform/devices/6c80000.soundwire/power/control") == "on" ]] ||
  fail "post resume restores 6c80000.soundwire to on"
[[ $(<"$f_a16/sys/bus/platform/devices/6ca0000.soundwire/power/control") == "auto" ]] ||
  fail "post resume preserves 6ca0000.soundwire auto state"
[[ $(<"$f_a16/sys/bus/platform/devices/a400000.usb/power/wakeup") == "enabled" ]] ||
  fail "post resume restores a400000.usb wakeup"
[[ $(<"$f_a16/sys/bus/platform/devices/a600000.usb/power/wakeup") == "disabled" ]] ||
  fail "post resume preserves user-disabled a600000.usb wakeup"
[[ $(<"$f_a16/sys/bus/platform/devices/a800000.usb/power/wakeup") == "enabled" ]] ||
  fail "post resume restores a800000.usb wakeup"
[[ $(<"$f_a16/bt_0") == "unblocked" ]] ||
  fail "post resume unblocks Bluetooth adapter 0"
[[ $(<"$f_a16/bt_1") == "blocked" ]] ||
  fail "post resume keeps user-blocked Bluetooth adapter 1 blocked"

# Respect already-blocked Bluetooth
f_bt_off="$scratch/sleep-bt-off"
make_sleep_fixture "$f_bt_off" UX3607OA blocked
run_sleep_hook "$f_bt_off" pre suspend
run_sleep_hook "$f_bt_off" post suspend
[[ $(<"$f_bt_off/bt_0") == "blocked" ]] ||
  fail "post resume keeps Bluetooth blocked when it was already blocked"
[[ ! -e $f_bt_off/rfkill.log ]] ||
  fail "already-blocked Bluetooth is not touched by rfkill"

# SoundWire active timeout logs a warning and still completes cleanly
f_sdw_busy="$scratch/sleep-sdw-busy"
make_sleep_fixture "$f_sdw_busy" UX3607OA blocked "" on active
sdw_warn=$(run_sleep_hook "$f_sdw_busy" pre hybrid-sleep 2>&1)
[[ $sdw_warn == *"SoundWire stayed active"* ]] ||
  fail "SoundWire timeout logs a warning to stderr"

# Post without prior pre is a safe no-op
f_post_only="$scratch/sleep-post-only"
make_sleep_fixture "$f_post_only" UX3607OA blocked "" auto suspended
run_sleep_hook "$f_post_only" post suspend-then-hibernate
[[ $(<"$f_post_only/sys/bus/platform/devices/6ca0000.soundwire/power/control") == "auto" ]] ||
  fail "post without prior pre leaves SoundWire unchanged"
[[ $(<"$f_post_only/bt_0") == "blocked" ]] ||
  fail "post without prior pre leaves Bluetooth unchanged"

# No-op on hibernate and on other machines (nothing modified)
f_other="$scratch/sleep-other"
make_sleep_fixture "$f_other" OTHER_BOARD unblocked
run_sleep_hook "$f_other" pre suspend
[[ $(<"$f_other/sys/bus/pci/devices/0004:00:00.0/power/wakeup") == "enabled" ]] ||
  fail "other machines are not modified by the sleep hook (PCIe root port)"
[[ $(<"$f_other/sys/bus/pci/devices/0004:01:00.0/power/wakeup") == "enabled" ]] ||
  fail "other machines are not modified by the sleep hook (PCIe endpoint)"
[[ $(<"$f_other/sys/bus/platform/devices/6c80000.soundwire/power/control") == "on" ]] ||
  fail "other machines keep their SoundWire power control"
[[ $(<"$f_other/sys/bus/platform/devices/a400000.usb/power/wakeup") == "enabled" ]] ||
  fail "other machines keep their USB wakeup"
[[ $(<"$f_other/bt_0") == "unblocked" && ! -e $f_other/rfkill.log ]] ||
  fail "other machines keep their Bluetooth untouched"
[[ -z $(ls -A "$f_other/run") ]] ||
  fail "other machines leave no /run state behind"

f_hib="$scratch/sleep-hib"
make_sleep_fixture "$f_hib" UX3607OA unblocked
run_sleep_hook "$f_hib" pre hibernate
[[ $(<"$f_hib/sys/bus/platform/devices/6c80000.soundwire/power/control") == "on" ]] ||
  fail "hibernate skips s2idle sleep hook"

echo "ok - ASUS Zenbook A16 front camera relay, tuning, WirePlumber rules, guard, power rules and deep sleep"
