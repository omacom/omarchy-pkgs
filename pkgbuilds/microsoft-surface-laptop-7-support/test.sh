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
