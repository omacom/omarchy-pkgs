#!/bin/bash
set -euo pipefail

# Every x86_64 linux-omarchy recipe ships Intel IPU7 modules prebuilt as $kernel-ipu7 from the
# same commit and patches that intel-ipu7-camera ships in intel-ipu7-drivers-dkms.
# Keep both in step so a security or hardware patch cannot land in only one.

REPO_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
PKGBUILDS=${1:-"$REPO_ROOT/pkgbuilds"}
CAMERA="$PKGBUILDS/intel-ipu7-camera"
KERNELS=(linux-omarchy linux-omarchy-eevdf linux-omarchy-muqss)

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

recipe() {
  (CARCH=x86_64; source "$1/PKGBUILD"; eval "$2")
}

camera_ver=$(recipe "$CAMERA" 'echo "$pkgver"')
camera_commit=$(recipe "$CAMERA" 'echo "$_ipu7_drivers_commit"')
mapfile -t camera_patches < <(recipe "$CAMERA" 'printf "%s\n" "${source[@]##*/}"' | grep -E '^[0-9]+-ipu7-.*\.patch$')

for kernel in "${KERNELS[@]}"; do
  KERNEL="$PKGBUILDS/$kernel"

  kernel_ver=$(recipe "$KERNEL" 'echo "$_ipu7ver"')
  [[ $kernel_ver == "$camera_ver" ]] || fail "$kernel builds IPU7 ${kernel_ver:-nothing}, intel-ipu7-camera is $camera_ver"

  kernel_commit=$(recipe "$KERNEL" 'echo "$_ipu7_drivers_commit"')
  [[ $kernel_commit == "$camera_commit" ]] || fail "$kernel pins ipu7-drivers ${kernel_commit:-nothing}, intel-ipu7-camera pins $camera_commit"

  mapfile -t kernel_sources < <(recipe "$KERNEL" 'printf "%s\n" "${source[@]##*/}"')

  for patch in "${camera_patches[@]}"; do
    copy="ipu7-$patch"
    printf '%s\n' "${kernel_sources[@]}" | grep -xF "$copy" >/dev/null || fail "$kernel does not build with $copy"
    cmp -s "$CAMERA/$patch" "$KERNEL/$copy" || fail "$KERNEL/$copy differs from intel-ipu7-camera's $patch"
  done

  for src in "${kernel_sources[@]}"; do
    [[ $src == ipu7-*.patch ]] || continue
    printf '%s\n' "${camera_patches[@]}" | grep -xF "${src#ipu7-}" >/dev/null || fail "$kernel carries $src, which intel-ipu7-camera dropped"
  done
done

echo "IPU7 $camera_ver ($camera_commit) and ${#camera_patches[@]} patches in step between intel-ipu7-camera and ${#KERNELS[@]} kernels"
