#!/bin/bash
set -euo pipefail

# Every linux-omarchy recipe builds its $kernel-nvidia-open modules from the
# driver nvidia-open-dkms ships, pinned to nvidia-utils, which
# lib32-nvidia-utils pins too. A driver update that misses one of them ships
# modules that no longer match nvidia-utils, a userspace pacman cannot
# install, or ARM modules without a fix the DKMS package carries.

REPO_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
PKGBUILDS=${1:-"$REPO_ROOT/pkgbuilds"}
DKMS="$PKGBUILDS/nvidia-open-dkms"
ARM_KERNEL="$PKGBUILDS/linux-omarchy-aarch64"
KERNELS=(linux-omarchy linux-omarchy-eevdf linux-omarchy-muqss linux-omarchy-aarch64)
DRIVER=(nvidia-utils nvidia-open-dkms lib32-nvidia-utils)

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Sourcing reads the recipes' variables without running any of their functions.
recipe() {
  (CARCH=$1; source "$2/PKGBUILD"; eval "$3")
}

version=$(recipe x86_64 "$PKGBUILDS/nvidia-utils" 'echo "$pkgver"')

for package in "${DRIVER[@]}"; do
  found=$(recipe x86_64 "$PKGBUILDS/$package" 'echo "$pkgver"')
  [[ $found == "$version" ]] || fail "$package is NVIDIA $found, nvidia-utils is $version"
done

for kernel in "${KERNELS[@]}"; do
  found=$(recipe x86_64 "$PKGBUILDS/$kernel" 'echo "$_nvidiaver"')
  [[ $found == "$version" ]] || fail "$kernel builds NVIDIA ${found:-nothing}, nvidia-utils is $version"
done

mapfile -t kernel_sources < <(recipe aarch64 "$ARM_KERNEL" 'printf "%s\n" "${source[@]##*/}"')
mapfile -t dkms_patches < <(recipe aarch64 "$DKMS" 'printf "%s\n" "${source_aarch64[@]##*/}"' | grep '\.patch$')

for patch in "${dkms_patches[@]}"; do
  copy="nvidia-$patch"
  printf '%s\n' "${kernel_sources[@]}" | grep -qxF "$copy" || fail "linux-omarchy-aarch64 does not build with $copy"
  cmp -s "$DKMS/$patch" "$ARM_KERNEL/$copy" || fail "$ARM_KERNEL/$copy differs from nvidia-open-dkms's $patch"
done

for source in "${kernel_sources[@]}"; do
  [[ $source == nvidia-*.patch ]] || continue
  printf '%s\n' "${dkms_patches[@]}" | grep -qxF "${source#nvidia-}" || fail "linux-omarchy-aarch64 carries $source, which nvidia-open-dkms dropped"
done

echo "NVIDIA $version in ${#DRIVER[@]} driver recipes and ${#KERNELS[@]} kernels, ${#dkms_patches[@]} ARM patches in step"
