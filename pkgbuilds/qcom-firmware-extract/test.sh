#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
extractor="$package_dir/qcom-firmware-extract"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# macOS' install(1) gives -D a different meaning. Prefer GNU coreutils when
# this focused test runs on a contributor's Mac; Arch uses GNU install already.
test_bin="$scratch/bin"
mkdir -p "$test_bin"
if command -v ginstall >/dev/null 2>&1; then
  ln -s "$(command -v ginstall)" "$test_bin/install"
fi

dt_root="$scratch/device-tree"
firmware_root="$scratch/firmware"
driver_store="$scratch/DriverStore"
stage="$scratch/stage"
node="$dt_root/remoteproc@0"
firmware_path="qcom/x1e80100/LENOVO/83ED"

mkdir -p "$node" "$firmware_root/$firmware_path" \
  "$driver_store/wrong" "$driver_store/matching"
printf '%s\0%s\0' \
  "$firmware_path/qccdsp8380.mbn" \
  "$firmware_path/cdsp_dtbs.elf" >"$node/firmware-name"

# Make the incompatible Windows firmware newer than the matching variant.
printf 'installed-cdsp' >"$firmware_root/$firmware_path/qccdsp8380.mbn"
printf 'other-cdsp' >"$driver_store/wrong/qccdsp8380.mbn"
printf 'wrong-dtb' >"$driver_store/wrong/cdsp_dtbs.elf"
printf 'installed-cdsp' >"$driver_store/matching/qccdsp8380.mbn"
printf 'matching-dtb' >"$driver_store/matching/cdsp_dtbs.elf"
touch -t 203001010000 "$driver_store/wrong/cdsp_dtbs.elf"
touch -t 202001010000 "$driver_store/matching/cdsp_dtbs.elf"

QCOM_FW_DT_ROOT="$dt_root" \
  QCOM_FW_FIRMWARE_ROOT="$firmware_root" \
  PATH="$test_bin:$PATH" \
  bash "$extractor" --stage "$stage" -d "$driver_store"

[[ $(<"$stage/$firmware_path/cdsp_dtbs.elf") == matching-dtb ]] || {
  echo "not ok - extractor did not select the DTB matching the installed DSP image" >&2
  exit 1
}

echo "ok - extractor selects an ambiguous DTB by its companion firmware hash"

run_extractor() {
  QCOM_FW_DT_ROOT="$dt_root" \
    QCOM_FW_FIRMWARE_ROOT="$firmware_root" \
    QCOM_FW_ROOT="$scratch/root" \
    PATH="$test_bin:$PATH" \
    bash "$extractor" "$@"
}

# A different remote processor must not supply the matching companion.
mkdir -p "$dt_root/remoteproc@1" "$driver_store/unrelated"
printf '%s\0' "$firmware_path/qcadsp8380.mbn" >"$dt_root/remoteproc@1/firmware-name"
printf 'installed-adsp' >"$firmware_root/$firmware_path/qcadsp8380.mbn"
printf 'installed-adsp' >"$driver_store/unrelated/qcadsp8380.mbn"
printf 'unrelated-dtb' >"$driver_store/unrelated/cdsp_dtbs.elf"
printf 'missing-cdsp' >"$firmware_root/$firmware_path/qccdsp8380.mbn"
run_extractor --stage "$scratch/unmatched" -d "$driver_store"
[[ ! -e $scratch/unmatched/$firmware_path/cdsp_dtbs.elf ]]
echo "ok - companion matching stays within the exact device-tree node"

# Firmware not found in Windows must not stop other files from being staged.
printf '%s\0%s\0%s\0' "$firmware_path/not-in-windows.mbn" \
  "$firmware_path/cdsp_dtbs.elf" "$firmware_path/qccdsp8380.mbn" >"$node/firmware-name"
printf 'installed-cdsp' >"$firmware_root/$firmware_path/qccdsp8380.mbn"
run_extractor --stage "$scratch/partial" -d "$driver_store"
[[ $(<"$scratch/partial/$firmware_path/cdsp_dtbs.elf") == matching-dtb ]]
run_extractor --install --no-rebuild --stage-dir "$scratch/partial"
[[ $(<"$firmware_root/updates/$firmware_path/cdsp_dtbs.elf") == matching-dtb ]]
echo "ok - missing firmware does not abort staging or installation"

# With no companion, only byte-identical duplicates are safe to select.
printf '%s\0' "$firmware_path/duplicate.mbn" >"$node/firmware-name"
printf 'one' >"$driver_store/wrong/duplicate.mbn"
printf 'two' >"$driver_store/matching/duplicate.mbn"
run_extractor --stage "$scratch/ambiguous" -d "$driver_store"
[[ ! -e $scratch/ambiguous/$firmware_path/duplicate.mbn ]]
printf 'one' >"$driver_store/matching/duplicate.mbn"
run_extractor --stage "$scratch/identical" -d "$driver_store"
[[ $(<"$scratch/identical/$firmware_path/duplicate.mbn") == one ]]
echo "ok - differing variants require a unique match"

# A packaged zap shader still needs an initramfs entry when nothing is missing.
printf '%s\0' "$firmware_path/qccdsp8380.mbn" >"$node/firmware-name"
mkdir -p "$dt_root/gpu@0/zap-shader"
printf '%s\0' "$firmware_path/qcdxkmsuc8380.mbn" >"$dt_root/gpu@0/zap-shader/firmware-name"
zap="$firmware_path/qcdxkmsuc8380.mbn"
config="$scratch/root/etc/mkinitcpio.conf.d/qcom-firmware.conf"
for compression in zstd xz; do
  if [[ $compression == zstd ]]; then suffix=zst; else suffix=xz; fi
  printf 'zap' | "$compression" -c >"$firmware_root/$zap.$suffix"
  run_extractor --install --no-rebuild -d "$driver_store"
  [[ -z $(run_extractor --list-missing) ]]
  grep -Fq "$zap.$suffix" "$config"
  rm "$firmware_root/$zap.$suffix"
done
echo "ok - zstd and xz firmware are loadable and included in the initramfs"

printf 'zap' | gzip >"$firmware_root/$zap.gz"
[[ $(run_extractor --list-missing) == "$zap" ]]
run_extractor --install --no-rebuild -d "$driver_store"
[[ ! -e $config ]]
printf 'zap' >"$driver_store/matching/qcdxkmsuc8380.mbn"
run_extractor --install --no-rebuild -d "$driver_store"
cmp "$driver_store/matching/qcdxkmsuc8380.mbn" "$firmware_root/updates/$zap"
grep -Fq "updates/$zap" "$config"
echo "ok - gzip does not hide missing firmware or prevent extraction"

# Compressed updates must not take precedence over a plain packaged file.
mv "$firmware_root/updates/$zap" "$firmware_root/$zap"
printf 'update' | zstd -c >"$firmware_root/updates/$zap.zst"
run_extractor --install --no-rebuild -d "$driver_store"
grep -Fq "$firmware_root/$zap" "$config"
if grep -Fq "updates/$zap" "$config"; then
  echo "not ok - firmware selection differs from the kernel search order" >&2
  exit 1
fi
printf 'update' >"$firmware_root/updates/$zap"
run_extractor --install --no-rebuild -d "$driver_store"
grep -Fq "updates/$zap" "$config"
echo "ok - plain firmware is preferred before compressed directory overrides"

limine-update() { printf 'rebuild\n' >>"$QCOM_FW_ROOT/rebuilds"; }
export -f limine-update
run_extractor --install -d "$driver_store"
[[ ! -e $scratch/root/rebuilds ]]
rm "$scratch/root/etc/mkinitcpio.conf.d/qcom-firmware.conf"
run_extractor --install -d "$driver_store"
[[ $(<"$scratch/root/rebuilds") == rebuild ]]
echo "ok - configuration-only changes rebuild the initramfs once"
