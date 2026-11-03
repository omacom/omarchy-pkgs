#!/bin/bash
set -euo pipefail

# linux-omarchy-aarch64 builds linux-omarchy-nvidia-open from the same driver
# and patches nvidia-open-dkms ships, pinned to nvidia-utils. Updating one
# NVIDIA recipe without the kernel's copy would ship prebuilt modules that no
# longer match nvidia-utils, or that miss a fix the DKMS package carries.

REPO_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
PKGBUILDS=${1:-"$REPO_ROOT/pkgbuilds"}
KERNEL="$PKGBUILDS/linux-omarchy-aarch64"
DKMS="$PKGBUILDS/nvidia-open-dkms"
UTILS="$PKGBUILDS/nvidia-utils"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Sourcing reads the recipes' variables without running any of their functions.
recipe() {
  (CARCH=aarch64; source "$1/PKGBUILD"; eval "$2")
}

kernel_nvidia=$(recipe "$KERNEL" 'echo "$_nvidiaver"')
dkms_version=$(recipe "$DKMS" 'echo "$pkgver"')
utils_version=$(recipe "$UTILS" 'echo "$pkgver"')

[[ $kernel_nvidia == "$dkms_version" ]] || fail "linux-omarchy-aarch64 builds NVIDIA $kernel_nvidia, nvidia-open-dkms is $dkms_version"
[[ $kernel_nvidia == "$utils_version" ]] || fail "linux-omarchy-aarch64 builds NVIDIA $kernel_nvidia, nvidia-utils is $utils_version"

mapfile -t kernel_sources < <(recipe "$KERNEL" 'printf "%s\n" "${source[@]##*/}"')
mapfile -t dkms_patches < <(recipe "$DKMS" 'printf "%s\n" "${source[@]##*/}"' | grep '\.patch$')

for patch in "${dkms_patches[@]}"; do
  copy="nvidia-$patch"
  printf '%s\n' "${kernel_sources[@]}" | grep -qxF "$copy" || fail "linux-omarchy-aarch64 does not build with $copy"
  cmp -s "$DKMS/$patch" "$KERNEL/$copy" || fail "$KERNEL/$copy differs from nvidia-open-dkms's $patch"
done

for source in "${kernel_sources[@]}"; do
  [[ $source == nvidia-*.patch ]] || continue
  printf '%s\n' "${dkms_patches[@]}" | grep -qxF "${source#nvidia-}" || fail "linux-omarchy-aarch64 carries $source, which nvidia-open-dkms dropped"
done

echo "linux-omarchy-nvidia-open matches nvidia-open-dkms and nvidia-utils $kernel_nvidia (${#dkms_patches[@]} patches)"
