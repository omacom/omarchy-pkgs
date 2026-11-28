#!/bin/bash
# Verify lib32-nvidia-580xx-utils split packages ship working licenses (no
# self-referential ELOOP or dangling symlinks), pin nvidia-580xx-utils to the
# exact pkgver, and share a lockstep group with nvidia-580xx-utils.
set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
nvidia_dir="$package_dir/../nvidia-580xx-utils"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

# Verify the 64-bit nvidia-580xx-utils recipe installs LICENSE into the
# directory lib32-nvidia-580xx-utils symlinks to (ignoring comments).
expected_license_dir="nvidia-utils"
grep -Eq "^[[:space:]]*install[[:space:]].*/usr/share/licenses/${expected_license_dir}/LICENSE([\"'[:space:]]|\$)" \
  "$nvidia_dir/PKGBUILD" ||
  fail "nvidia-580xx-utils no longer installs /usr/share/licenses/${expected_license_dir}/LICENSE"

# Verify both recipes declare the same lockstep group so version bumps ship together.
lib32_lockstep=$(jq -r '.lockstep // empty' "$package_dir/.omarchy/package.json")
nvidia_lockstep=$(jq -r '.lockstep // empty' "$nvidia_dir/.omarchy/package.json")
[[ -n "$lib32_lockstep" && "$lib32_lockstep" == "$nvidia_lockstep" ]] ||
  fail "lib32-nvidia-580xx-utils and nvidia-580xx-utils must share a lockstep group"

# Stub the extracted NVIDIA .run tree (top-level LICENSE + 32-bit libraries).
setup_stub_tree() {
  local src=$1 ver=$2
  local top="$src/NVIDIA-Linux-x86_64-${ver}"
  local dir="$top/32"
  mkdir -p "$dir"
  printf 'NVIDIA license\n' > "$top/LICENSE"
  local libs=(
    libnvidia-opencl.so
    libGLX_nvidia.so
    libEGL_nvidia.so
    libGLESv1_CM_nvidia.so
    libGLESv2_nvidia.so
    libnvidia-glcore.so
    libnvidia-eglcore.so
    libnvidia-glsi.so
    libnvidia-fbc.so
    libnvidia-encode.so
    libnvidia-ml.so
    libnvidia-glvkspirv.so
    libnvidia-allocator.so
    libnvidia-gpucomp.so
    libvdpau_nvidia.so
    libnvidia-tls.so
    libcuda.so
    libnvcuvid.so
    libnvidia-ptxjitcompiler.so
    libnvidia-opticalflow.so
  )
  local lib
  for lib in "${libs[@]}"; do
    : > "$dir/${lib}.${ver}"
  done
}

# Run each split package function in an isolated subshell so per-split overrides
# (pkgname, depends, pkgdir) match makepkg semantics.
run_split() {
  local split=$1 out_pkgdir=$2 out_deps=$3
  (
    # shellcheck source=/dev/null
    source "$package_dir/PKGBUILD"
    srcdir="$scratch/src"
    pkgdir="$out_pkgdir"
    # shellcheck disable=SC2034 # Used by package_*() functions from PKGBUILD.
    pkgname="$split"
    setup_stub_tree "$srcdir" "$pkgver"
    mkdir -p "$pkgdir"
    # shellcheck disable=SC2329 # Invoked indirectly by create_links() in PKGBUILD.
    readelf() { return 0; }
    cd "$srcdir"
    "package_${split}"
    # shellcheck disable=SC2154 # Set by package_*() in PKGBUILD.
    printf '%s\n' "${depends[@]}" > "$out_deps"
  )
}

pkgver=$(bash -c 'source "$1"; printf "%s" "$pkgver"' _ "$package_dir/PKGBUILD")
nvidia_pkgver=$(bash -c 'source "$1"; printf "%s" "$pkgver"' _ "$nvidia_dir/PKGBUILD")
[[ "$pkgver" == "$nvidia_pkgver" ]] ||
  fail "lib32-nvidia-580xx-utils ($pkgver) must stay in lockstep with nvidia-580xx-utils ($nvidia_pkgver)"

# 1. lib32-nvidia-580xx-utils: depends on nvidia-580xx-utils=$pkgver and symlinks to its license dir.
utils_pkgdir="$scratch/pkg-utils"
utils_deps="$scratch/deps-utils"
run_split "lib32-nvidia-580xx-utils" "$utils_pkgdir" "$utils_deps"

grep -qxF "nvidia-580xx-utils=${pkgver}" "$utils_deps" ||
  fail "lib32-nvidia-580xx-utils depends must pin nvidia-580xx-utils=${pkgver}"

utils_lic="$utils_pkgdir/usr/share/licenses/lib32-nvidia-580xx-utils"
[[ -L "$utils_lic" ]] ||
  fail "lib32-nvidia-580xx-utils missing license symlink at /usr/share/licenses/lib32-nvidia-580xx-utils"
utils_target=$(readlink "$utils_lic")
[[ "$utils_target" != "lib32-nvidia-580xx-utils" ]] ||
  fail "lib32-nvidia-580xx-utils license symlink loops onto itself (ELOOP)"
[[ "$utils_target" == "$expected_license_dir" ]] ||
  fail "lib32-nvidia-580xx-utils license symlink targets '$utils_target', expected '$expected_license_dir'"

# Stand-in root containing only what the declared dependency (nvidia-580xx-utils) installs.
utils_root="$scratch/root-utils"
mkdir -p "$utils_root/usr/share/licenses/${expected_license_dir}"
printf 'NVIDIA license\n' > "$utils_root/usr/share/licenses/${expected_license_dir}/LICENSE"
cp -a "$utils_pkgdir/usr/share/licenses/." "$utils_root/usr/share/licenses/"
[[ -s "$utils_root/usr/share/licenses/lib32-nvidia-580xx-utils/LICENSE" ]] ||
  fail "lib32-nvidia-580xx-utils license symlink does not resolve to LICENSE"

# 2. lib32-opencl-nvidia-580xx: does not depend on nvidia-580xx-utils, so it must ship its own LICENSE.
opencl_pkgdir="$scratch/pkg-opencl"
opencl_deps="$scratch/deps-opencl"
run_split "lib32-opencl-nvidia-580xx" "$opencl_pkgdir" "$opencl_deps"

for dep in lib32-zlib lib32-gcc-libs; do
  grep -qxF "$dep" "$opencl_deps" ||
    fail "lib32-opencl-nvidia-580xx missing runtime dependency $dep"
done

opencl_lic_dir="$opencl_pkgdir/usr/share/licenses/lib32-opencl-nvidia-580xx"
[[ ! -L "$opencl_lic_dir" && -d "$opencl_lic_dir" ]] ||
  fail "lib32-opencl-nvidia-580xx must ship a standalone license directory (not a dangling symlink)"
[[ ! -e "$opencl_pkgdir/usr/share/licenses/lib32-opencl-nvidia" && ! -L "$opencl_pkgdir/usr/share/licenses/lib32-opencl-nvidia" ]] ||
  fail "lib32-opencl-nvidia-580xx must not install a license entry under unversioned lib32-opencl-nvidia"

# Empty root (no nvidia-580xx-utils installed): OpenCL license must resolve standalone.
opencl_root="$scratch/root-opencl"
mkdir -p "$opencl_root/usr/share/licenses"
cp -a "$opencl_pkgdir/usr/share/licenses/." "$opencl_root/usr/share/licenses/"
[[ -f "$opencl_root/usr/share/licenses/lib32-opencl-nvidia-580xx/LICENSE" && -s "$opencl_root/usr/share/licenses/lib32-opencl-nvidia-580xx/LICENSE" ]] ||
  fail "lib32-opencl-nvidia-580xx license does not exist standalone"

echo "ok - lib32-nvidia-580xx-utils"
