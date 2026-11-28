#!/usr/bin/env bash
# Resolve the Vulkan driver file names inside a staged Mesa tree.
#
# Aurora renamed its Vulkan driver to Borealis (Ryan 2026-11-20): the driver
# library becomes libvulkan_borealis.so and the ICD manifest becomes
# borealis_icd.<arch>.json. The Khronos enum entry keeps its Honeykrisp
# name and the meson option keeps an "asahi" alias, so a build tree can hold
# either spelling. These helpers name whichever spelling is present.
#
# Usage:
#   source vulkan-driver-names.sh
#   driver_library "$srcdir/mesa-stage/usr/lib"   # -> libvulkan_asahi.so or libvulkan_borealis.so
#   driver_icd "$srcdir/mesa-stage/usr/share/vulkan/icd.d"  # -> the ICD JSON file name

# The driver library file name, preferring the Borealis name.
driver_library() {
  local dir=$1
  if [[ -f "$dir/libvulkan_borealis.so" ]]; then
    echo "libvulkan_borealis.so"
  elif [[ -f "$dir/libvulkan_asahi.so" ]]; then
    echo "libvulkan_asahi.so"
  else
    echo "no Vulkan driver library (libvulkan_borealis.so or libvulkan_asahi.so) in $dir" >&2
    return 1
  fi
}

# The ICD manifest file name, preferring the Borealis name.
driver_icd() {
  local dir=$1
  local candidate
  for candidate in "$dir"/borealis_icd.*.json "$dir"/asahi_icd.*.json; do
    if [[ -f "$candidate" ]]; then
      basename "$candidate"
      return 0
    fi
  done
  echo "no Vulkan ICD manifest (borealis_icd.*.json or asahi_icd.*.json) in $dir" >&2
  return 1
}
