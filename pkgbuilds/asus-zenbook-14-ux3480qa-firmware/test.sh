#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

source "$package_dir/PKGBUILD"
[[ " ${arch[*]} " == " aarch64 " ]] || fail "the package is aarch64-only"
[[ -z ${groups[*]:-} ]] || fail "the package is in no group, so only the UX3480QA installs it"

# Omarchy installs the package that provides qcom-firmware-<folder> for each
# folder the device tree asks for (install/hardware/qualcomm/oem-firmware.sh).
dir=qcom/x1p42100/ASUSTeK/zenbook-14-ux3480qa
[[ " ${provides[*]} " == *" qcom-firmware-x1p42100-asustek-zenbook-14-ux3480qa "* ]] ||
  fail "provides qcom-firmware-<folder> for $dir"

# Stand in for the unpacked board support package. The fixture's bytes cannot
# match the real firmware's sums, so stub sha256sum and check what it is given.
srcdir="$scratch/src"
bsp="$srcdir/asus-socpackage-50883/QualcommBSP"
files=(
  Subsystem/qcsubsys_ext_adsp8380/qcadsp8380.mbn
  Subsystem/qcsubsys_ext_adsp8380/adsp_dtbs.elf
  Subsystem/qcsubsys_ext_adsp8380/adspr.jsn
  Subsystem/qcsubsys_ext_adsp8380/adsps.jsn
  Subsystem/qcsubsys_ext_adsp8380/adspua.jsn
  Subsystem/qcsubsys_ext_adsp8380/battmgr.jsn
  NPU/qcnspmcdm_ext_cdsp8380/qccdsp8380.mbn
  NPU/qcnspmcdm_ext_cdsp8380/cdsp_dtbs.elf
  NPU/qcnspmcdm_ext_cdsp8380/cdspr.jsn
  GFX/qcdx8380/qcdxkmsucpurwa.mbn
  GFX/qcdx8380/qcvss8380.mbn
)
for f in "${files[@]}"; do
  mkdir -p "$bsp/$(dirname "$f")"
  echo "$f" >"$bsp/$f"
done
sha256sum() { cat >"$scratch/sums"; }

pkgdir="$scratch/pkg"
(cd "$srcdir" && package)

# The names x1p42100-asus-zenbook-14-ux3480qa.dts gives the ADSP, CDSP, GPU zap
# shader and Iris, and the DSP services beside them, compressed with xz so a copy
# linux-firmware ships under the same name is the one the kernel loads.
for f in "${files[@]}"; do
  [[ $(xz -dc "$pkgdir/usr/lib/firmware/$dir/${f##*/}.xz") == "$f" ]] ||
    fail "installs ${f##*/}.xz unmodified where the device tree asks for ${f##*/}"
  grep -qE "^[0-9a-f]{64}  $dir/${f##*/}\$" "$scratch/sums" || fail "checks ${f##*/} against its sha256"
done
[[ $(find "$pkgdir" -type f | wc -l) -eq ${#files[@]} ]] || fail "installs nothing else"
[[ -z $(find "$pkgdir" -type f ! -name '*.xz') ]] || fail "installs no path linux-firmware could also ship"

echo "ok - asus-zenbook-14-ux3480qa-firmware"
