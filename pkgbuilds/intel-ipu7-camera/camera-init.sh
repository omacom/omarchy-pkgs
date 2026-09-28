#!/bin/bash
# Load the IPU7 camera modules, then rebind OV08X40 if S3 left the I2C client
# unbound. After resume the modules are already loaded, so modprobe is a no-op
# and the bind is the step that actually restores the sensor.

SYSFS="${CAMERA_INIT_SYSFS:-/sys}"

if [[ "${CAMERA_INIT_SKIP_MODPROBE:-0}" != 1 ]]; then
  modprobe intel_cvs && sleep 2 && modprobe ov08x40 && modprobe v4l2loopback || exit 1
fi

hid_dir="${SYSFS}/bus/i2c/devices/i2c-OVTI08F4:00"
bind_file="${SYSFS}/bus/i2c/drivers/ov08x40/bind"

[[ -e "$hid_dir" ]] || exit 0
[[ -e "${hid_dir}/driver" ]] && exit 0
[[ -e "$bind_file" ]] || exit 0

if [[ -L "$hid_dir" ]]; then
  i2c_id=$(basename "$(readlink -f "$hid_dir")")
else
  i2c_id=$(basename "$hid_dir")
  i2c_id="${i2c_id#i2c-}"
fi

# Kernel bind wants the numeric client id (17-0036), not the ACPI alias.
[[ -n "$i2c_id" ]] || exit 0
[[ "$i2c_id" == *:* ]] && exit 0

printf '%s\n' "$i2c_id" >"$bind_file" 2>/dev/null || true
exit 0
