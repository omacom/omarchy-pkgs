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

sh -n "$package_dir/anduril-bluechip-support.install" ||
  fail "install scriptlet has valid POSIX sh syntax"
grep -q 'systemctl stop bluechip-camera-guard.service v4l2-relayd@bluechip.service' "$package_dir/anduril-bluechip-support.install" ||
  fail "install scriptlet stops retired system camera services on upgrade"

echo "ok - Anduril BlueChip front camera system plumbing (loopback, WirePlumber rules, dma_heap udev)"
