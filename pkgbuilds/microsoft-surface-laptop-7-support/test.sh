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

read_pack romulus13 bix other || fail "another laptop is left alone without an error"
[[ ! -e $scratch/out/other ]] || fail "nothing is read on another laptop"

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

echo "ok - Surface Laptop 7 battery reader and command"

# The sound card check. WirePlumber's view is a pw-dump fixture that a fake
# restart swaps for the next one; UCM's device list is the one alsaucm prints.
checker="$package_dir/surface-laptop-7-audio-profiles"

card() {
  local profiles='{"name": "off"}, {"name": "pro-audio"}' name
  for name in "$@"; do
    profiles+=", {\"name\": \"$name\"}"
  done
  cat <<EOF_CARD
[{"type": "PipeWire:Interface:Node", "info": {"props": {"node.name": "other"}}},
 {"type": "PipeWire:Interface:Device",
  "info": {"props": {"device.name": "alsa_card.platform-sound", "api.alsa.path": "hw:3"},
           "params": {"EnumProfile": [$profiles]}}}]
EOF_CARD
}

cat >"$scratch/ucm" <<'EOF_UCM'
  0: Speaker
    Speaker playback
  1: Headphones
    Headphones playback
  2: Headset
    Headset microphone
  3: Mic
    Internal microphones
  4: HDMI0
    USB/DisplayPort 0 playback
  5: HDMI1
    USB/DisplayPort 1 playback
EOF_UCM

card 'HiFi (HDMI1, Headset, Mic, Speaker)' 'HiFi (HDMI0, Headset, Mic, Speaker)' \
  'HiFi (Headphones, Headset, Mic, Speaker)' >"$scratch/card.whole"
card >"$scratch/card.bare"
card 'HiFi (HDMI0, Headset, Mic, Speaker)' >"$scratch/card.reduced"

# check <compatible> <view before any restart> [view after each restart...]
check() {
  local compatible=$1
  shift
  rm -f "$scratch"/view.* "$scratch/restarts" "$scratch/asked"
  local n=0 view
  for view in "$@"; do
    cp "$scratch/card.$view" "$scratch/view.$n"
    n=$((n + 1))
  done
  SL7_AUDIO_COMPATIBLE="$scratch/$compatible" SL7_AUDIO_WAIT=1 SL7_AUDIO_SETTLE=0 \
    SL7_AUDIO_PW_DUMP="cat '$scratch'/view.\$(cat '$scratch/restarts' 2>/dev/null | wc -l)" \
    SL7_AUDIO_UCM_DEVICES="echo {card} >>'$scratch/asked'; cat '$scratch/ucm'" \
    SL7_AUDIO_RESTART="echo restart >>'$scratch/restarts'" \
    python "$checker" >"$scratch/said" 2>&1
}

restarts() {
  if [[ -e $scratch/restarts ]]; then
    wc -l <"$scratch/restarts"
  else
    echo 0
  fi
}

check romulus15 whole || fail "a card with every device is accepted"
[[ $(restarts) == 0 ]] || fail "a card with every device restarts nothing"
grep -qx 'hw:3' "$scratch/asked" || fail "UCM is asked about the card WirePlumber names"

check romulus15 bare whole || fail "a card left with Off and Pro Audio is repaired"
[[ $(restarts) == 1 ]] || fail "one restart repairs a card that then has every device"
grep -q 'without HDMI0, HDMI1, Headphones, Headset, Mic, Speaker' "$scratch/said" ||
  fail "the missing devices are named"

check romulus15 reduced whole || fail "a card missing some outputs is repaired"
grep -q 'without HDMI1, Headphones;' "$scratch/said" || fail "only the missing outputs are named"

check romulus15 bare reduced whole || fail "a second restart is tried"
[[ $(restarts) == 2 ]] || fail "a card repaired by the second restart took two"

if check romulus15 bare bare bare bare; then
  fail "a card that stays broken is reported as a failure"
fi
[[ $(restarts) == 2 ]] || fail "WirePlumber is restarted at most twice"

rm -f "$scratch"/view.* "$scratch/restarts"
if SL7_AUDIO_COMPATIBLE="$scratch/romulus15" SL7_AUDIO_WAIT=1 SL7_AUDIO_PW_DUMP="echo '[]'" \
  SL7_AUDIO_UCM_DEVICES="cat '$scratch/ucm'" SL7_AUDIO_RESTART="echo restart >>'$scratch/restarts'" \
  python "$checker" 2>/dev/null; then
  fail "a card that never appears is reported as a failure"
fi
[[ $(restarts) == 0 ]] || fail "nothing is restarted for a card that never appears"

cp "$scratch/card.whole" "$scratch/view.0"
if SL7_AUDIO_COMPATIBLE="$scratch/romulus15" SL7_AUDIO_WAIT=1 SL7_AUDIO_PW_DUMP="cat '$scratch/view.0'" \
  SL7_AUDIO_UCM_DEVICES="false" SL7_AUDIO_RESTART="echo restart >>'$scratch/restarts'" \
  python "$checker" 2>/dev/null; then
  fail "a card UCM cannot open is reported as a failure"
fi
[[ $(restarts) == 0 ]] || fail "nothing is restarted while UCM cannot open the card"

check romulus13 bare || fail "another laptop is left alone without an error"
[[ $(restarts) == 0 && ! -e $scratch/asked ]] || fail "nothing is checked on another laptop"

echo "ok - Surface Laptop 7 sound card check"
