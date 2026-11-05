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
# board.bin is ath12k's fallback for every QCC2072, so no other laptop may get it.
[[ -z ${groups[*]:-} ]] || fail "the package is in no group, so only the UX3607OA installs it"

# Stand in for the unpacked board support package.
srcdir="$scratch/src"
bsp="$srcdir/bsp/QualcommBSP"
mkdir -p "$bsp/Subsystem/qcsubsys_ext_adsp8480" "$bsp/NPU/qcnspmcdm8480" "$bsp/WIFI_BT/qcwlancol8480"
for f in Subsystem/qcsubsys_ext_adsp8480/qcadsp8480.mbn Subsystem/qcsubsys_ext_adsp8480/adsp_dtbs.elf \
  NPU/qcnspmcdm8480/qccdsp8480.mbn NPU/qcnspmcdm8480/cdsp_dtbs.elf \
  WIFI_BT/qcwlancol8480/bdwlan_qcc2072_1p0_ncm820A.elf; do
  echo "$f" > "$bsp/$f"
done
cp "$package_dir/asus,zenbook-a16-ux3607oa.list" "$srcdir/"

pkgdir="$scratch/pkg"
(cd "$srcdir" && package)

fw="$pkgdir/usr/lib/firmware"
# The names glymur-asus-zenbook-a16-ux3607oa.dts gives the ADSP and CDSP, compressed with xz so a
# copy linux-firmware ships under the same name is the one the kernel loads.
for f in qcadsp8480.mbn adsp_dtbs.elf qccdsp8480.mbn cdsp_dtbs.elf; do
  [[ $(xz -dc "$fw/qcom/glymur/ASUSTeK/UX3607OA/$f.xz") == */$f ]] || fail "installs $f.xz where the device tree asks for $f"
done
[[ $(xz -dc "$fw/ath12k/QCC2072/hw1.0/board.bin.xz") == WIFI_BT/qcwlancol8480/bdwlan_qcc2072_1p0_ncm820A.elf ]] ||
  fail "installs the NCM820A board data as ath12k's board.bin"
[[ -z $(find "$fw" -type f ! -name '*.xz') ]] || fail "installs no firmware path linux-firmware could also ship"

list="$pkgdir/usr/share/qcom-firmware-extract/provided.d/asus,zenbook-a16-ux3607oa.list"
[[ -f $list ]] || fail "tells qcom-firmware-extract which firmware the board does not need from Windows"
for f in qcadsp8480.mbn adsp_dtbs.elf qccdsp8480.mbn cdsp_dtbs.elf soccp.mbn soccp_dtb.mbn; do
  grep -qx "qcom/glymur/ASUSTeK/UX3607OA/$f" "$list" || fail "lists $f as provided"
done

echo "ok - asus-zenbook-a16-firmware"
