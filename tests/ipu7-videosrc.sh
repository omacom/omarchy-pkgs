#!/bin/bash
set -euo pipefail

REPO_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

script="$REPO_ROOT/pkgbuilds/intel-ipu7-camera/camera-videosrc-init"
packaged=$(sed -n 's/^VIDEOSRC="\(.*\)"$/\1/p' "$REPO_ROOT/pkgbuilds/intel-ipu7-camera/v4l2-relayd-ipu7.conf")
[[ $packaged == *"device-name=ov08x40-uf"*"videoflip method=rotate-180"* ]] ||
  { echo "FAIL: packaged VIDEOSRC changed shape: $packaged" >&2; exit 1; }

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# A board: the subdevs the kernel registered, the bridge ACPI ids, and the
# sensor configs the HAL ships.
board() {
  rm -rf "$TEST_ROOT/sys" "$TEST_ROOT/camera"
  mkdir -p "$TEST_ROOT/sys/bus/acpi/devices" "$TEST_ROOT/camera/ipu7x/sensors" "$TEST_ROOT/camera/ipu75xa/sensors"
  touch "$TEST_ROOT/camera/ipu7x/sensors/"{ov08x40,imx471,ov02c10}-uf.json
  touch "$TEST_ROOT/camera/ipu75xa/sensors/"{ov08x40,imx471}-uf.json
  local i=0 name
  for name in "$@"; do
    case $name in
      INTC*) mkdir -p "$TEST_ROOT/sys/bus/acpi/devices/$name:00" ;;
      *)
        mkdir -p "$TEST_ROOT/sys/class/video4linux/v4l-subdev$i"
        printf '%s\n' "$name" >"$TEST_ROOT/sys/class/video4linux/v4l-subdev$i/name"
        i=$((i + 1))
        ;;
    esac
  done
}

# Prints the VIDEOSRC the relay will use: the override when one was written,
# the configured one otherwise.
run() {
  local env="$TEST_ROOT/videosrc.env"
  echo stale >"$env"
  VIDEOSRC=${1:-$packaged} IPU7_SYSFS="$TEST_ROOT/sys" IPU7_CAMERA_CONFIG="$TEST_ROOT/camera" \
    IPU7_VIDEOSRC_ENV="$env" bash "$script" || fail "script exited $?"
  if [[ -e $env ]]; then
    [[ $(<"$env") != stale ]] || fail "stale override survived"
    (set -a; source "$env"; printf '%s\n' "$VIDEOSRC")
  else
    printf '%s\n' "${1:-$packaged}"
  fi
}

expect() {
  local got=$1 want=$2 label=$3
  [[ $got == "$want" ]] || fail "$label: got '$got', want '$want'"
}

imx471=${packaged/device-name=ov08x40-uf/device-name=imx471-uf}

# ThinkPad X9 Gen 1: IMX471 on Lunar Lake without the CVS bridge, mounted
# inverted (camera_sensor_rotation = 180), so the rotation stays.
board "Intel IPU7 CSI2 0" "imx471 0-0010" INTC1069
expect "$(run)" "$imx471" "IMX471 board uses imx471-uf and keeps rotation"

# Panther Lake XPS: ov08x40 behind CVS, as packaged, so nothing is written.
board "Intel IPU7 CSI2 0" "Intel CVS" "ov08x40 0-0036" INTC10E1
expect "$(run)" "$packaged" "ov08x40 Panther Lake board unchanged"
[[ ! -e $TEST_ROOT/videosrc.env ]] || fail "override written with nothing to change"

# Lunar Lake with the CVS bridge: rotation dropped, sensor kept.
board "ov08x40 0-0036" INTC10DE
expect "$(run)" "${packaged/ ! videoflip method=rotate-180/}" "ov08x40 Lunar Lake drops rotation"

# Both at once.
board "imx471 0-0010" INTC10DE
expect "$(run)" "${imx471/ ! videoflip method=rotate-180/}" "IMX471 Lunar Lake with CVS"

# A sensor the HAL has no config for keeps the configured camera.
board "hi556 1-0010" INTC1069
expect "$(run)" "$packaged" "unsupported sensor keeps configured name"

# No sensor bound yet keeps the configured camera.
board "Intel IPU7 CSI2 0" INTC1069
expect "$(run)" "$packaged" "no bound sensor keeps configured name"

# A user pipeline without device-name is left alone.
board "imx471 0-0010" INTC1069
expect "$(run "icamerasrc ! videoconvert")" "icamerasrc ! videoconvert" "pipeline without device-name"

# systemd metacharacters survive the EnvironmentFile round trip.
board "imx471 0-0010" INTC1069
quoted='icamerasrc device-name=ov08x40-uf ! textoverlay text="a $b `c` \d"'
expect "$(run "$quoted")" "${quoted/ov08x40-uf/imx471-uf}" "quoting"

echo 'PASS: 8 IPU7 relay pipeline cases'
