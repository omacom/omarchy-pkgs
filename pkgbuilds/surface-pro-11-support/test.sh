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
grep -A1 -- '- BlackLevel:' "$package_dir/imx681.yaml" | grep -q 'blackLevel: 4096$' ||
  fail "the front camera tuning carries the measured IMX681 black level"

bin="$scratch/bin"
mkdir -p "$bin"

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

# Pen: iptsd is stopped before sleep and a fresh process started after resume.
cat >"$bin/systemctl" <<'STUB'
#!/bin/bash
case $1 in
  list-units) printf 'iptsd@dev-hidraw5.service loaded active running Intel Precise Touch & Stylus Daemon\n' ;;
  *) printf '%s\n' "$*" >>"$SYSTEMCTL_LOG" ;;
esac
STUB
chmod +x "$bin/systemctl"
iptsd_sleep() {
  PATH="$bin:$PATH" SYSTEMCTL_LOG="$scratch/systemctl.log" SP11_IPTSD_STATE="$scratch/iptsd.units" \
    SP11_IPTSD_COMPATIBLE="$scratch/$1" SP11_IPTSD_SETTLE=0 bash "$package_dir/surface-pro-11-iptsd-sleep" "${@:2}"
}
iptsd_sleep other pre suspend
[[ ! -e $scratch/systemctl.log ]] || fail "iptsd is left alone on other hardware"
iptsd_sleep denali pre suspend
iptsd_sleep denali post suspend
[[ $(<"$scratch/systemctl.log") == $'stop iptsd@dev-hidraw5.service\nstart iptsd@dev-hidraw5.service' ]] ||
  fail "iptsd restarts across suspend, since the touch controller resets on resume"
iptsd_sleep denali post suspend
[[ $(wc -l <"$scratch/systemctl.log") == 2 ]] ||
  fail "a resume without a matching stop starts nothing"

# Lid: wake on the lid only when suspending with it closed; an open lid's
# false edge in CX collapse would wake the machine at once.
cat >"$bin/busctl" <<'STUB'
#!/bin/bash
[[ -n ${LID_CLOSED:-} ]] || exit 1
echo "b $LID_CLOSED"
STUB
chmod +x "$bin/busctl"
lid_wakeup="$scratch/lid-wakeup"
lid_sleep() {
  PATH="$bin:$PATH" SP11_LID_WAKE_SYSFS="$lid_wakeup" SP11_LID_WAKE_COMPATIBLE="$scratch/$1" \
    bash "$package_dir/surface-pro-11-lid-wake-sleep" "${@:2}"
}
echo enabled >"$lid_wakeup"
LID_CLOSED=false lid_sleep denali pre suspend >/dev/null
[[ $(<"$lid_wakeup") == disabled ]] || fail "suspending with the lid open turns lid wake off"
LID_CLOSED=true lid_sleep denali pre suspend >/dev/null
[[ $(<"$lid_wakeup") == enabled ]] || fail "suspending with the lid closed arms lid wake"
LID_CLOSED= lid_sleep denali pre suspend >/dev/null
[[ $(<"$lid_wakeup") == disabled ]] || fail "an unknown lid state counts as open"
echo enabled >"$lid_wakeup"
LID_CLOSED=false lid_sleep other pre suspend
LID_CLOSED=false lid_sleep denali post suspend
[[ $(<"$lid_wakeup") == enabled ]] || fail "the lid hook acts only before suspend on the Surface Pro 11"

# Flex Keyboard: pair on attach when there is no working bond, reconnect on
# detach. bluetoothctl, btmgmt and the pairing tool are stubs that record what
# they were asked to do.
cat >"$bin/bluetoothctl" <<'STUB'
#!/bin/bash
case $1 in
  show) printf '\tPowered: yes\n' ;;
  info)
    [[ -e $BT_STATE/paired ]] || exit 1
    printf '\tPaired: yes\n\tBonded: yes\n'
    if [[ -e $BT_STATE/connected ]]; then printf '\tConnected: yes\n'; else printf '\tConnected: no\n'; fi
    ;;
  connect) echo "connect $2" >>"$BT_STATE/log"; [[ ! -e $BT_STATE/connectable ]] || : >"$BT_STATE/connected" ;;
  remove) echo "remove $2" >>"$BT_STATE/log"; rm -f "$BT_STATE/paired" "$BT_STATE/connected" ;;
  *) echo "$*" >>"$BT_STATE/log" ;;
esac
STUB
cat >"$bin/btmgmt" <<'STUB'
#!/bin/bash
echo "btmgmt $*" >>"$BT_STATE/log"
STUB
cat >"$bin/logger" <<'STUB'
#!/bin/bash
STUB
cat >"$bin/fake-flex-pair" <<'STUB'
#!/bin/bash
echo "pair $*" >>"$BT_STATE/log"
[[ ${PAIR_FAILS:-} ]] && exit 1
: >"$BT_STATE/paired"; : >"$BT_STATE/connected"
STUB
chmod +x "$bin/bluetoothctl" "$bin/btmgmt" "$bin/logger" "$bin/fake-flex-pair"

keyboard=C5:45:77:5A:A0:E8
flex_reset() {
  rm -rf "$scratch/bt" "$scratch/run" "$scratch/hid"
  mkdir -p "$scratch/bt" "$scratch/run" "$scratch/hid"
  : >"$scratch/bt/log"
}
flex_attach() { mkdir -p "$scratch/hid/0019:045E:0C8B.0002" "$scratch/hid/0019:045E:0C8F.0001"; }
flex_bond() { echo "$keyboard" >"$scratch/bt/address"; : >"$scratch/bt/paired"; }
flex() {
  PATH="$bin:$PATH" BT_STATE="$scratch/bt" SP11_FLEX_COMPATIBLE="$scratch/$1" \
    SP11_FLEX_HID_DEVICES="$scratch/hid" SP11_FLEX_ADDRESS_FILE="$scratch/bt/address" \
    SP11_FLEX_RUN_DIR="$scratch/run" SP11_FLEX_PAIR_TOOL="$bin/fake-flex-pair" SP11_FLEX_NO_SLEEP=1 \
    bash "$package_dir/surface-pro-11-flex-$2" >/dev/null 2>&1 || true
}
flex_did() { grep -qx "$1" "$scratch/bt/log"; }

flex_reset; flex_attach
flex other autopair
! flex_did "pair --no-detach" || fail "the Flex Keyboard is left alone on other hardware"

flex_reset; flex_attach
flex denali autopair
flex_did "pair --no-detach" || fail "an attached keyboard with no bond is paired over the wire"

flex_reset; flex_attach; flex_bond; : >"$scratch/bt/connected"
flex denali autopair
[[ ! -s $scratch/bt/log ]] || fail "a working bond is left alone"

# The bond would even connect on request: only the marker says it is stale.
flex_reset; flex_attach; flex_bond; : >"$scratch/bt/connectable"; : >"$scratch/run/flex-needs-repair"
flex denali autopair
flex_did "remove $keyboard" && flex_did "pair --no-detach" ||
  fail "a bond that failed to reconnect on detach is replaced on the next attach"
[[ ! -e $scratch/run/flex-needs-repair ]] || fail "a successful pair clears the repair marker"

flex_reset; flex_attach; flex_bond
flex denali autopair
flex_did "btmgmt power off" && flex_did "remove $keyboard" && flex_did "pair --no-detach" ||
  fail "a bond that will not connect even after a controller reset is replaced"

flex_reset; flex_attach; flex_bond; : >"$scratch/bt/connectable"
flex denali autopair
! flex_did "pair --no-detach" || fail "a bond that connects on request is kept"

flex_reset; mkdir -p "$scratch/hid/0019:045E:0C8B.0002"
flex denali autopair
! flex_did "pair --no-detach" || fail "without the kernel's pairing channel nothing is paired"

flex_reset
flex denali autopair
! flex_did "pair --no-detach" || fail "a detached keyboard is not paired"

flex_reset; flex_bond; : >"$scratch/bt/connectable"
flex denali reconnect
flex_did "connect $keyboard" && [[ ! -e $scratch/run/flex-needs-repair ]] ||
  fail "a detached keyboard is connected over Bluetooth"

flex_reset; flex_bond
flex denali reconnect
[[ -e $scratch/run/flex-needs-repair ]] || fail "a detached keyboard that never connects is marked for re-pairing"

flex_reset; flex_attach; flex_bond
flex denali reconnect
! flex_did "connect $keyboard" || fail "an attached keyboard is not connected over Bluetooth"

python -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$package_dir/surface-pro-11-flex-pair" ||
  fail "the pairing tool is valid Python"
for unit in surface-pro-11-flex-autopair surface-pro-11-flex-reconnect; do
  grep -qx 'ConditionFirmware=device-tree-compatible(microsoft,denali-oled)' "$package_dir/$unit.service" ||
    fail "$unit runs only on the Surface Pro 11 OLED"
  grep -q "start $unit.service" "$package_dir/70-surface-pro-11-flex-keyboard.rules" ||
    fail "attaching or detaching the keyboard starts $unit"
done

echo "ok - surface-pro-11-support verifies its hardware setup"
