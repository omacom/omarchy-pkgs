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

echo "ok - Anduril BlueChip front camera system plumbing (loopback, WirePlumber rules, dma_heap udev)"
