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

# CPU power: each profile caps every policy at the nearest supported frequency.
cpufreq="$scratch/cpufreq"
for policy in policy0 policy4; do
  mkdir -p "$cpufreq/$policy"
  printf '710400\n' >"$cpufreq/$policy/cpuinfo_min_freq"
  printf '3417600\n' >"$cpufreq/$policy/cpuinfo_max_freq"
  printf '710400 1920000 2515200 3417600\n' >"$cpufreq/$policy/scaling_available_frequencies"
  printf '710400\n' >"$cpufreq/$policy/scaling_min_freq"
  printf '3417600\n' >"$cpufreq/$policy/scaling_max_freq"
done
cpu_profile() {
  printf '%s\n' "$1" >"$scratch/profile"
  SP11_CPUFREQ_ROOT="$cpufreq" SP11_PLATFORM_PROFILE_PATH="$scratch/profile" \
    python "$package_dir/surface-pro-11-power-profile-cpufreq" --apply-once >/dev/null
  cat "$cpufreq/policy0/scaling_max_freq" "$cpufreq/policy4/scaling_max_freq" | sort -u
}
[[ $(cpu_profile low-power) == 1920000 ]] || fail "power-saver caps the CPUs at 1.92 GHz"
[[ $(cpu_profile balanced) == 2515200 ]] || fail "balanced caps the CPUs at 2.52 GHz"
[[ $(cpu_profile performance) == 3417600 ]] || fail "performance restores the full range"
printf 'quiet\n' >"$scratch/profile"
if SP11_CPUFREQ_ROOT="$cpufreq" SP11_PLATFORM_PROFILE_PATH="$scratch/profile" \
  python "$package_dir/surface-pro-11-power-profile-cpufreq" --apply-once >/dev/null 2>&1; then
  fail "an unknown profile is rejected rather than guessed"
fi

grep -qx 'ConditionFirmware=device-tree-compatible(microsoft,denali-oled)' "$package_dir/surface-pro-11-power-profile-cpufreq.service" ||
  fail "the CPU limit service runs only on the Surface Pro 11 OLED"

echo "ok - surface-pro-11-support verifies its hardware setup"
