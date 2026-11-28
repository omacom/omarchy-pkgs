#!/usr/bin/env bash
# Self-test for the Vulkan driver file-name resolver used by the omarchy-mlx
# and mesa-aurora PKGBUILDs: Aurora renamed the driver to Borealis, and the
# staged Mesa tree can carry either spelling (Ryan 2026-11-20).
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
# One helper copy must stay byte-identical to the other: both PKGBUILDs
# source their own file, so drift here means the packages disagree.
if ! cmp -s "$ROOT/pkgbuilds/omarchy-mlx/vulkan-driver-names.sh" \
            "$ROOT/pkgbuilds/mesa-aurora/vulkan-driver-names.sh"; then
  echo "FAIL: pkgbuilds/omarchy-mlx/vulkan-driver-names.sh and pkgbuilds/mesa-aurora/vulkan-driver-names.sh differ" >&2
  exit 1
fi
# shellcheck source=pkgbuilds/omarchy-mlx/vulkan-driver-names.sh
source "$ROOT/pkgbuilds/omarchy-mlx/vulkan-driver-names.sh"
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

expect() {
  local what=$1 want=$2 got=$3
  if [[ "$got" == "$want" ]]; then
    pass "$what"
  else
    fail "$what: wanted '$want', got '$got'"
  fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The Borealis spelling (what Aurora's tree carries after the rename).
mkdir -p "$tmp/borealis/usr/lib" "$tmp/borealis/usr/share/vulkan/icd.d"
touch "$tmp/borealis/usr/lib/libvulkan_borealis.so"
touch "$tmp/borealis/usr/share/vulkan/icd.d/borealis_icd.aarch64.json"
expect "the Borealis driver library is found" "libvulkan_borealis.so" \
  "$(driver_library "$tmp/borealis/usr/lib")"
expect "the Borealis ICD manifest is found" "borealis_icd.aarch64.json" \
  "$(driver_icd "$tmp/borealis/usr/share/vulkan/icd.d")"

# The legacy spelling (today's Mesa tree).
mkdir -p "$tmp/legacy/usr/lib" "$tmp/legacy/usr/share/vulkan/icd.d"
touch "$tmp/legacy/usr/lib/libvulkan_asahi.so"
touch "$tmp/legacy/usr/share/vulkan/icd.d/asahi_icd.aarch64.json"
expect "the legacy driver library is found" "libvulkan_asahi.so" \
  "$(driver_library "$tmp/legacy/usr/lib")"
expect "the legacy ICD manifest is found" "asahi_icd.aarch64.json" \
  "$(driver_icd "$tmp/legacy/usr/share/vulkan/icd.d")"

# Both present: the renamed one wins, so a mixed tree is not ambiguous.
cp "$tmp/borealis/usr/lib/libvulkan_borealis.so" "$tmp/legacy/usr/lib/"
cp "$tmp/borealis/usr/share/vulkan/icd.d/borealis_icd.aarch64.json" \
  "$tmp/legacy/usr/share/vulkan/icd.d/"
expect "a tree with both spellings resolves to Borealis" "libvulkan_borealis.so" \
  "$(driver_library "$tmp/legacy/usr/lib")"
expect "a tree with both ICD spellings resolves to Borealis" "borealis_icd.aarch64.json" \
  "$(driver_icd "$tmp/legacy/usr/share/vulkan/icd.d")"

# Neither present: the helper refuses instead of naming a file that is not there.
mkdir -p "$tmp/empty/usr/lib" "$tmp/empty/usr/share/vulkan/icd.d"
if driver_library "$tmp/empty/usr/lib" >/dev/null 2>&1; then
  fail "an empty tree must not resolve a driver library"
else
  pass "an empty tree refuses a driver library"
fi
if driver_icd "$tmp/empty/usr/share/vulkan/icd.d" >/dev/null 2>&1; then
  fail "an empty tree must not resolve an ICD manifest"
else
  pass "an empty tree refuses an ICD manifest"
fi

echo "All driver-name resolver checks passed."
