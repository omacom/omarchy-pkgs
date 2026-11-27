#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

fail() {
  echo "not ok - $1" >&2
  exit 1
}

grep -q 'card_label="Front Camera"' "$package_dir/bluechip-camera-modprobe.conf" ||
  fail "the loopback device is labelled Front Camera"
grep -q 'exclusive_caps=1' "$package_dir/bluechip-camera-modprobe.conf" ||
  fail "the loopback device uses exclusive_caps=1"

cameras="$package_dir/50-bluechip-cameras.conf"
grep -q 'api.libcamera.path = "/base/soc@0/cci@ac16000/i2c-bus@1/camera@10"' "$cameras" ||
  fail "pickers hide the raw OV08X40 camera owned by the relay"
grep -q 'device.bus-path = "platform-acb6000.isp"' "$cameras" || fail "pickers hide the raw Glymur CAMSS nodes"

grep -qx 'SUBSYSTEM=="dma_heap", KERNEL=="system", TAG+="uaccess"' "$package_dir/70-bluechip-camera.rules" ||
  fail "udev grants uaccess on the system dma_heap"

install_script="$package_dir/anduril-bluechip-support.install"
sh -n "$install_script" || fail "install scriptlet has valid POSIX sh syntax"

# Exercise pre_upgrade and post_upgrade with a stub systemctl when systemd is present.
if [[ -d /run/systemd/system ]]; then
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  cat >"$work/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$MOCK_LOG"
SH
  chmod +x "$work/systemctl"

  MOCK_LOG="$work/log" PATH="$work:$PATH" sh -c '
    . "$1"
    pre_upgrade 1-8 1-6
    post_upgrade 1-8 1-7
  ' _ "$install_script"
  grep -qx 'stop bluechip-camera-guard.service v4l2-relayd@bluechip.service' "$work/log" ||
    fail "upgrade scriptlet stops retired services when upgrading from < 1-8"
  grep -qx 'daemon-reload' "$work/log" ||
    fail "post_upgrade reloads systemd when upgrading from < 1-8"

  : >"$work/log"
  MOCK_LOG="$work/log" PATH="$work:$PATH" sh -c '
    . "$1"
    pre_upgrade 1-9 1-8
    post_upgrade 1-9 1-8
  ' _ "$install_script"
  [[ ! -s $work/log ]] || fail "upgrade scriptlet is a no-op once already on >= 1-8"
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch" "${work:-}"' EXIT

# Power management udev rules
power_rules="$package_dir/90-anduril-bluechip-power.rules"
if command -v udevadm >/dev/null 2>&1; then
  udevadm verify --no-style "$power_rules" >/dev/null ||
    fail "the power rules pass udevadm verify"
fi
grep -qx 'ATTR{\[dmi/id\]sys_vendor}=="Anduril", ATTR{\[dmi/id\]board_name}=="NY4P9", GOTO="bluechip_power_start"' "$power_rules" ||
  fail "the power rules use a positive DMI guard for the Anduril BlueChip"
awk '
  /\\$/ { sub(/\\$/, ""); buf = buf $0; next }
  { print buf $0; buf = "" }
' "$power_rules" >"$scratch/power.rules"
grep -q 'DRIVER=="dwc3-qcom",.*ATTR{power/control}="auto", ATTR{power/autosuspend_delay_ms}="200"' "$scratch/power.rules" ||
  fail "the dwc3-qcom rule enables autosuspend with 200 ms delay"
grep -q 'DRIVER=="xhci-hcd",.*ATTR{power/control}="auto"' "$scratch/power.rules" ||
  fail "the xhci-hcd rule enables runtime PM"
grep -q 'DRIVER=="qcom-qmp-combo-phy|qcom-qmp-usb-phy",.*ATTR{power/control}="auto"' "$scratch/power.rules" ||
  fail "the QMP PHY rule enables runtime PM"
awk '
  /^LABEL="bluechip_power_start"$/ { inside = 1; next }
  /^LABEL="bluechip_power_end"$/ { inside = 0; next }
  inside && /KERNEL=="0004:00:00\.0\|0004:01:00\.0".*ATTR\{power\/wakeup\}="disabled"/ { found = 1 }
  END { exit !found }
' "$scratch/power.rules" ||
  fail "the PCIe4 Wi-Fi root port and endpoint wakeup rule sits inside the DMI guard"

# Sleep config
grep -qx 'MemorySleepMode=s2idle' "$package_dir/60-bluechip-sleep.conf" ||
  fail "the sleep config selects s2idle"

# Sleep hook
sleep_hook="$package_dir/bluechip-sleep"
bash -n "$sleep_hook" || fail "the sleep hook has valid syntax"

make_sleep_fixture() {
  local dir=$1 compat=$2 bt0=$3 bt1=${4:-}
  mkdir -p \
    "$dir/sys/firmware/devicetree/base" \
    "$dir/sys/bus/pci/devices/0004:00:00.0/power" \
    "$dir/sys/bus/pci/devices/0004:01:00.0/power" \
    "$dir/sys/bus/platform/devices/a200000.usb/power" \
    "$dir/sys/bus/platform/devices/a400000.usb/power" \
    "$dir/sys/bus/platform/devices/a600000.usb/power" \
    "$dir/sys/bus/platform/devices/a800000.usb/power" \
    "$dir/run"
  printf '%s\0qcom,glymur\0' "$compat" >"$dir/sys/firmware/devicetree/base/compatible"
  printf 'enabled\n' >"$dir/sys/bus/pci/devices/0004:00:00.0/power/wakeup"
  printf 'enabled\n' >"$dir/sys/bus/pci/devices/0004:01:00.0/power/wakeup"
  printf 'enabled\n' >"$dir/sys/bus/platform/devices/a200000.usb/power/wakeup"
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
  BLUECHIP_SLEEP_SYSFS="$dir/sys" \
    BLUECHIP_SLEEP_RUN_DIR="$dir/run" \
    BLUECHIP_SLEEP_RFKILL="$dir/rfkill" \
    BLUECHIP_SLEEP_BT_SETTLE=0 \
    bash "$sleep_hook" "$@"
}

f_bc="$scratch/sleep-bc"
make_sleep_fixture "$f_bc" anduril,bluechip unblocked blocked
run_sleep_hook "$f_bc" pre suspend
[[ $(<"$f_bc/sys/bus/pci/devices/0004:00:00.0/power/wakeup") == "disabled" &&
   $(<"$f_bc/sys/bus/pci/devices/0004:01:00.0/power/wakeup") == "disabled" ]] ||
  fail "pre suspend disables PCIe4 Wi-Fi root port and endpoint wakeup"
[[ $(<"$f_bc/sys/bus/platform/devices/a200000.usb/power/wakeup") == "disabled" &&
   $(<"$f_bc/sys/bus/platform/devices/a400000.usb/power/wakeup") == "disabled" &&
   $(<"$f_bc/sys/bus/platform/devices/a600000.usb/power/wakeup") == "disabled" &&
   $(<"$f_bc/sys/bus/platform/devices/a800000.usb/power/wakeup") == "disabled" ]] ||
  fail "pre suspend disables USB wakeup across all four controllers"
[[ $(<"$f_bc/bt_0") == "blocked" && $(<"$f_bc/bt_1") == "blocked" ]] ||
  fail "pre suspend soft-blocks unblocked BT adapter 0"

run_sleep_hook "$f_bc" post suspend
[[ $(<"$f_bc/sys/bus/pci/devices/0004:00:00.0/power/wakeup") == "disabled" &&
   $(<"$f_bc/sys/bus/pci/devices/0004:01:00.0/power/wakeup") == "disabled" ]] ||
  fail "post resume keeps PCIe4 Wi-Fi wakeup disabled"
[[ $(<"$f_bc/sys/bus/platform/devices/a200000.usb/power/wakeup") == "enabled" &&
   $(<"$f_bc/sys/bus/platform/devices/a400000.usb/power/wakeup") == "enabled" &&
   $(<"$f_bc/sys/bus/platform/devices/a600000.usb/power/wakeup") == "disabled" &&
   $(<"$f_bc/sys/bus/platform/devices/a800000.usb/power/wakeup") == "enabled" ]] ||
  fail "post resume restores only previously enabled USB wakeups"
[[ $(<"$f_bc/bt_0") == "unblocked" && $(<"$f_bc/bt_1") == "blocked" ]] ||
  fail "post resume restores only previously unblocked BT adapter 0"

f_other="$scratch/sleep-other"
make_sleep_fixture "$f_other" asus,zenbook-a16-ux3607oa unblocked
run_sleep_hook "$f_other" pre suspend
[[ $(<"$f_other/sys/bus/pci/devices/0004:00:00.0/power/wakeup") == "enabled" &&
   $(<"$f_other/sys/bus/platform/devices/a200000.usb/power/wakeup") == "enabled" &&
   $(<"$f_other/bt_0") == "unblocked" && -z $(ls -A "$f_other/run") ]] ||
  fail "non-BlueChip boards are left untouched"

f_hib="$scratch/sleep-hib"
make_sleep_fixture "$f_hib" anduril,bluechip unblocked
run_sleep_hook "$f_hib" pre hibernate
[[ $(<"$f_hib/sys/bus/platform/devices/a200000.usb/power/wakeup") == "enabled" ]] ||
  fail "hibernate skips s2idle sleep hook"

echo "ok - Anduril BlueChip camera plumbing, power rules and deep sleep"
