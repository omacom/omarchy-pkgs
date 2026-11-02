#!/bin/bash
# SPDX-License-Identifier: MIT
# Never reset a running device. Repeated modprobe of a loaded module is inert.
set -eu
firmware_root=${AURORA_FIRMWARE_ROOT:-/lib/firmware}
compatible=${AURORA_DT_COMPATIBLE:-/sys/firmware/devicetree/base/compatible}
modprobe_command=${AURORA_MODPROBE:-modprobe}

has_firmware() {
  [ -s "$firmware_root/vendor/$1" ] || [ -s "$firmware_root/$1" ]
}

neo=false
if grep -aq 'apple,j700' "$compatible"; then
  neo=true
  if has_firmware apple/j700-aop-als-cal.bin; then
    "$modprobe_command" aop
  else
    echo 'Aurora: ALS calibration missing; Neo AOP probe deferred' >&2
  fi
  radio_ready=true
  # Only the world policy gates the radios: the driver falls back to it for
  # any country without its own policy file, so a missing US.bin (or any
  # other country) must not keep Wi-Fi, and with it Bluetooth, down.
  for name in \
    mediatek/mt7932/IZUBA_WIFI_MT7932_patch_mcu_1_2_hdr.bin \
    mediatek/mt7932/IZUBA_W7932_2.bin \
    mediatek/mt7932/ppr.bin mediatek/mt7932/oca2.bin \
    mediatek/mt7932/wcal.bin mediatek/mt7932/config-original.bin \
    mediatek/MT7932B0_OS_TypeB_0.1.44.0_241001003711.bin \
    mediatek/MT7932B1_OS_TypeB_0.1.133.0_260128190103.bin \
    mediatek/MT7932_PTB_IzubaA_0.1.0.0_20251021141303.ptx \
    mediatek/j700-mt7932-btcal.bin mediatek/j700-mt7932-bdaddr.bin \
    mediatek/mt7932/policy/world-XZ.bin; do
    if ! has_firmware "$name"; then
      echo "Aurora: required firmware is missing: $name; peripheral probe deferred" >&2
      radio_ready=false
    fi
  done
fi

if "$neo"; then
  if "$radio_ready"; then
    "$modprobe_command" mt7932-fullmac
    # Only the root firmware unit opts in. The initrd keeps Bluetooth out so
    # its Wi-Fi module dependency cannot probe before firmware extraction.
    if [ "${AURORA_ADMIT_BLUETOOTH:-0}" = 1 ]; then
      "$modprobe_command" mt7932_bt_pcie
    fi
  fi
else
  # Preserve ordinary non-Neo admission even if vendor extraction failed.
  "$modprobe_command" aop
fi
