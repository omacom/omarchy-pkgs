#!/bin/bash
# Pin: after S3, camera-init rebinds an unbound OVTI08F4 I2C client and is a
# no-op when the sensor is already bound or the HID is missing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$ROOT/camera-init.sh"
SERVICE="$ROOT/camera-init.service"
HOOK="$ROOT/camera-sleep-hook"

fail() { echo "FAIL: $*" >&2; exit 1; }

grep -q 'ExecStart=/usr/lib/intel-ipu7-camera/camera-init.sh' "$SERVICE" \
  || fail "camera-init.service does not ExecStart camera-init.sh"
if grep -q 'modprobe intel_cvs && sleep 2 && modprobe ov08x40' "$SERVICE"; then
  fail "camera-init.service still inlines modprobe-only ExecStart"
fi

grep -q -- '--unit=camera-resume' "$HOOK" \
  || fail "sleep hook lost --unit=camera-resume"

if grep -E -q 'rmmod|modprobe -r' "$SCRIPT"; then
  fail "camera-init.sh unloads modules"
fi

run_init() {
  CAMERA_INIT_SYSFS="$1" CAMERA_INIT_SKIP_MODPROBE=1 bash "$SCRIPT"
}

setup_sysfs() {
  local sysfs="$1" mode="$2"
  rm -rf "$sysfs"
  mkdir -p "$sysfs/bus/i2c/devices" "$sysfs/bus/i2c/drivers/ov08x40"
  : >"$sysfs/bus/i2c/drivers/ov08x40/bind"
  case "$mode" in
    unbound)
      mkdir -p "$sysfs/bus/i2c/devices/17-0036"
      ln -s "17-0036" "$sysfs/bus/i2c/devices/i2c-OVTI08F4:00"
      ;;
    bound)
      mkdir -p "$sysfs/bus/i2c/devices/17-0036"
      ln -s "17-0036" "$sysfs/bus/i2c/devices/i2c-OVTI08F4:00"
      ln -s "../../drivers/ov08x40" "$sysfs/bus/i2c/devices/17-0036/driver"
      ;;
    missing)
      mkdir -p "$sysfs/bus/i2c/devices/17-0036"
      ;;
  esac
}

bind_contents() {
  tr -d '[:space:]' <"$1/bus/i2c/drivers/ov08x40/bind"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

setup_sysfs "$TMP/unbound" unbound
run_init "$TMP/unbound"
got=$(bind_contents "$TMP/unbound")
[[ "$got" == "17-0036" ]] || fail "unbound fixture bind got '$got'"

setup_sysfs "$TMP/bound" bound
run_init "$TMP/bound"
got=$(bind_contents "$TMP/bound")
[[ -z "$got" ]] || fail "bound fixture wrote bind '$got'"

setup_sysfs "$TMP/missing" missing
run_init "$TMP/missing"
got=$(bind_contents "$TMP/missing")
[[ -z "$got" ]] || fail "missing HID wrote bind '$got'"

echo OK
