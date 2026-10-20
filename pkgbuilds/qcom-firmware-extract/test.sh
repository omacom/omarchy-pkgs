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

# Pin the kernel's firmware decompressors instead of reading /proc/config.gz.
export QCOM_FW_KERNEL_CONFIG="$scratch/config.gz"
set_kernel_config() { printf '%s\n' "$@" | gzip >"$QCOM_FW_KERNEL_CONFIG"; }
set_kernel_config CONFIG_FW_LOADER_COMPRESS_ZSTD=y CONFIG_FW_LOADER_COMPRESS_XZ=y

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

# Runs under a test root prefix, as if root.
run_extractor() {
  QCOM_FW_DT_ROOT="$dt_root" \
    QCOM_FW_FIRMWARE_ROOT="$firmware_root" \
    QCOM_FW_ROOT="$scratch/root" \
    QCOM_FW_TEST_EUID=0 \
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

# Windows names the Surface Pro 11's DSP device-tree images *_dtbs.elf.
surface_path="qcom/x1e80100/microsoft/Denali"
mkdir -p "$driver_store/surfacepro_ext_adsp8380"
printf '%s\0' "$surface_path/adsp_dtb.mbn" >"$node/firmware-name"
printf 'surface-adsp-dtb' >"$driver_store/surfacepro_ext_adsp8380/adsp_dtbs.elf"
run_extractor --stage "$scratch/windows-name" -d "$driver_store"
[[ $(<"$scratch/windows-name/$surface_path/adsp_dtb.mbn") == surface-adsp-dtb ]] || {
  echo "not ok - extractor did not find a DSP device-tree image under its Windows name" >&2
  exit 1
}
run_extractor --install --no-rebuild --stage-dir "$scratch/windows-name"
[[ $(<"$firmware_root/updates/$surface_path/adsp_dtb.mbn") == surface-adsp-dtb ]]
rm "$firmware_root/updates/$surface_path/adsp_dtb.mbn"
printf 'exact-name' >"$driver_store/surfacepro_ext_adsp8380/adsp_dtb.mbn"
run_extractor --stage "$scratch/exact-name" -d "$driver_store"
[[ $(<"$scratch/exact-name/$surface_path/adsp_dtb.mbn") == exact-name ]]
rm "$driver_store/surfacepro_ext_adsp8380/adsp_dtb.mbn"
echo "ok - DSP device-tree images are found under their Windows names, exact names first"

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

# A name that matches another as a regular expression keeps its manifest line.
printf 'first' >"$driver_store/matching/dotXmbn"
printf 'second' >"$driver_store/matching/dot.mbn"
printf '%s\0' "$firmware_path/dotXmbn" >"$node/firmware-name"
run_extractor --install --no-rebuild -d "$driver_store"
printf '%s\0' "$firmware_path/dot.mbn" >"$node/firmware-name"
run_extractor --install --no-rebuild -d "$driver_store"
[[ $(grep -c /dot "$scratch/root/var/lib/omarchy/qcom-firmware/manifest") == 2 ]]
echo "ok - manifest updates match firmware names exactly"

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

# Arch Linux ARM's kernel loads xz firmware but not zstd.
set_kernel_config CONFIG_FW_LOADER_COMPRESS_XZ=y
printf 'zap' | zstd -c >"$firmware_root/$zap.zst"
[[ $(run_extractor --list-missing) == "$zap" ]]
rm "$firmware_root/$zap.zst"
set_kernel_config CONFIG_FW_LOADER_COMPRESS_ZSTD=y CONFIG_FW_LOADER_COMPRESS_XZ=y
echo "ok - zstd firmware counts as missing when the kernel cannot load it"

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

# Reruns: an earlier stage, even an empty one, must not hide a later source.
rerun="$scratch/rerun"
rerun_dt="$rerun/device-tree"
adsp="qcom/glymur/vendor/board/qcadsp.mbn"
dtb="qcom/glymur/vendor/board/adsp_dtbs.elf"
windows_store="$rerun/windows/nvme0n1p3/Windows/System32/DriverStore/FileRepository/adsp.inf_1"
mkdir -p "$rerun_dt/remoteproc@0" "$rerun/root/run" "$rerun/empty-store" \
  "$rerun/store" "$rerun/adsp-only-store" "$windows_store"
printf '%s\0%s\0' "$adsp" "$dtb" >"$rerun_dt/remoteproc@0/firmware-name"
printf 'store-adsp' >"$rerun/store/qcadsp.mbn"
printf 'store-dtb' >"$rerun/store/adsp_dtbs.elf"
printf 'first-adsp' >"$rerun/adsp-only-store/qcadsp.mbn"
printf 'windows-adsp' >"$windows_store/qcadsp.mbn"
printf 'windows-dtb' >"$windows_store/adsp_dtbs.elf"

# For a subshell: NTFS partitions holding fake Windows trees $1/<device name>,
# by default one internal partition, or those that $TEST_PARTITIONS lists as
# "PATH|FSTYPE|TRAN|RM|HOTPLUG" lines, where a field may be empty. lsblk prints
# the requested columns as raw output does, an empty one as an empty string.
# The disk listing and each mount are recorded in $2.
# shellcheck disable=SC2329 # The stubs are exported to the extractor.
stub_windows_partition() {
  lsblk() {
    local arg previous="" path fstype tran rm hotplug column row
    local -a columns=()
    printf 'lsblk\n' >>"$TEST_SCAN_LOG"
    [[ -z ${TEST_NO_WINDOWS-} ]] || return 0
    for arg; do
      if [[ $previous == -*o ]]; then IFS=, read -ra columns <<<"$arg"; fi
      previous=$arg
    done
    while IFS='|' read -r path fstype tran rm hotplug; do
      row=""
      for column in "${columns[@]}"; do
        case $column in
          PATH) row+=" $path" ;;
          FSTYPE) row+=" $fstype" ;;
          TRAN) row+=" $tran" ;;
          RM) row+=" $rm" ;;
          HOTPLUG) row+=" $hotplug" ;;
        esac
      done
      printf '%s\n' "${row# }"
    done <<<"${TEST_PARTITIONS:-/dev/nvme0n1p3|ntfs|nvme|0|0}"
  }
  mount() {
    local device=${*: -2:1} mount_point=${*: -1}
    printf 'mount %s\n' "$device" >>"$TEST_SCAN_LOG"
    cp -R "$TEST_WINDOWS/${device##*/}/." "$mount_point/"
  }
  umount() { find "$1" -mindepth 1 -delete; }
  export -f lsblk mount umount
  export TEST_WINDOWS=$1 TEST_SCAN_LOG=$2
}

(
  stub_windows_partition "$rerun/windows" "$rerun/scan.log"

  run_rerun() {
    QCOM_FW_DT_ROOT="$rerun_dt" \
      QCOM_FW_FIRMWARE_ROOT="$rerun/firmware" \
      QCOM_FW_ROOT="$rerun/root" \
      QCOM_FW_TEST_EUID=${QCOM_FW_TEST_EUID-0} \
      PATH="$test_bin:$PATH" \
      bash "$extractor" "$@"
  }
  reset_installed() { rm -rf "$rerun/firmware" "$rerun/root/var" "$TEST_SCAN_LOG"; mkdir -p "$rerun/firmware"; }
  installed() { cat "$rerun/firmware/updates/$1"; }

  stage="$rerun/stage"
  run_rerun --stage "$stage" -d "$rerun/empty-store"
  [[ -f $stage/manifest && ! -s $stage/manifest ]]
  run_rerun --stage "$stage" -d "$rerun/store"
  [[ $(<"$stage/$adsp") == store-adsp && $(<"$stage/$dtb") == store-dtb ]]
  [[ $(grep -c . "$stage/manifest") == 2 ]]
  output=$(run_rerun --stage "$stage")
  [[ $output == *"already staged"* ]]
  [[ ! -e $TEST_SCAN_LOG ]]
  echo "ok - a stage rerun adds files an earlier, empty stage lacked"

  partial="$rerun/partial-stage"
  run_rerun --stage "$partial" -d "$rerun/adsp-only-store"
  run_rerun --stage "$partial" -d "$rerun/store"
  [[ $(<"$partial/$adsp") == first-adsp && $(<"$partial/$dtb") == store-dtb ]]
  [[ $(grep -c "^$adsp " "$partial/manifest") == 1 && $(grep -c . "$partial/manifest") == 2 ]]
  echo "ok - a stage rerun keeps staged files and their manifest lines"

  # Only the test switch stands in for root, not the test path prefix.
  rm -f "$TEST_SCAN_LOG"
  if output=$(QCOM_FW_TEST_EUID=1000 run_rerun --stage "$rerun/user-stage" 2>&1); then
    echo "not ok - a first stage without root read the partitions" >&2
    exit 1
  fi
  [[ $output == *"must run as root to read the Windows partitions"* && ! -e $TEST_SCAN_LOG ]]
  if QCOM_FW_TEST_EUID=1000 run_rerun --install --no-rebuild -d "$rerun/store" >/dev/null 2>&1; then
    echo "not ok - an install without root went ahead" >&2
    exit 1
  fi
  echo "ok - reading the partitions and installing need root"

  # A rerun without root cannot read Windows, so it keeps the stage it has.
  user_partial="$rerun/user-partial"
  run_rerun --stage "$user_partial" -d "$rerun/adsp-only-store"
  output=$(QCOM_FW_TEST_EUID=1000 run_rerun --stage "$user_partial")
  [[ $output == *"already staged in $user_partial; run as root"* && ! -e $TEST_SCAN_LOG ]]
  [[ $(grep -c . "$user_partial/manifest") == 1 ]]
  echo "ok - a stage rerun without root keeps a partial stage and succeeds"

  # Neither a stage rerun nor an install reads or rewrites the stage manifest
  # once per firmware name. External commands naming it are counted; reads
  # with bash builtins are not.
  probe="$rerun/probe-stage"
  run_rerun --stage "$probe" -d "$rerun/adsp-only-store"
  # shellcheck disable=SC2329 # The wrappers are exported to the extractor.
  (
    manifest_access() {
      local tool=$1 arg
      shift
      for arg; do
        if [[ $arg == "$probe/manifest"* ]]; then
          printf '%s\n' "$tool" >>"$rerun/manifest.log"
          break
        fi
      done
      command "$tool" "$@"
    }
    awk() { manifest_access awk "$@"; }
    cat() { manifest_access cat "$@"; }
    cp() { manifest_access cp "$@"; }
    grep() { manifest_access grep "$@"; }
    mv() { manifest_access mv "$@"; }
    sed() { manifest_access sed "$@"; }
    export -f manifest_access awk cat cp grep mv sed
    export probe rerun

    run_rerun --stage "$probe" -d "$rerun/store"
    [[ $(<"$probe/$dtb") == store-dtb && $(command grep -c . "$rerun/manifest.log") -le 1 ]]
    rm "$rerun/manifest.log"
    reset_installed
    run_rerun --install --no-rebuild --stage-dir "$probe"
    [[ $(installed "$adsp") == first-adsp && $(installed "$dtb") == store-dtb ]]
    [[ ! -e $rerun/manifest.log || $(command grep -c . "$rerun/manifest.log") -le 1 ]]
  )
  echo "ok - no per-name stage manifest scans or rewrites"

  mkdir -p "$rerun/empty-stage"
  : >"$rerun/empty-stage/manifest"
  reset_installed
  run_rerun --install --no-rebuild --stage-dir "$rerun/empty-stage"
  [[ $(installed "$adsp") == windows-adsp && $(installed "$dtb") == windows-dtb ]]
  echo "ok - an empty stage does not hide the Windows partition"

  dtb_stage="$rerun/dtb-stage"
  mkdir -p "$dtb_stage/${dtb%/*}"
  printf 'staged-dtb' >"$dtb_stage/$dtb"
  printf '%s %s %s\n' "$dtb" 0 test >"$dtb_stage/manifest"
  reset_installed
  run_rerun --install --no-rebuild --stage-dir "$dtb_stage"
  [[ $(installed "$dtb") == staged-dtb && $(installed "$adsp") == windows-adsp ]]
  echo "ok - Windows supplies what a partial stage lacks, and the stage comes first"

  reset_installed
  run_rerun --install --no-rebuild --stage-dir "$stage"
  [[ $(installed "$adsp") == store-adsp && $(installed "$dtb") == store-dtb ]]
  [[ ! -e $TEST_SCAN_LOG ]]
  echo "ok - a complete stage is used without mounting Windows"

  printf 'unlisted' >"$dtb_stage/$adsp"
  reset_installed
  run_rerun --install --no-rebuild --stage-dir "$dtb_stage"
  [[ $(installed "$adsp") == windows-adsp ]]
  echo "ok - only files recorded in the stage manifest count as staged"

  # A manifest line whose file is gone does not count as staged either.
  rm "$dtb_stage/$dtb"
  reset_installed
  run_rerun --install --no-rebuild --stage-dir "$dtb_stage"
  [[ $(installed "$dtb") == windows-dtb ]]
  printf 'staged-dtb' >"$dtb_stage/$dtb"
  echo "ok - a manifest line without its file does not count as staged"

  reset_installed
  run_rerun --install --no-rebuild --stage-dir "$stage" -d "$rerun/adsp-only-store"
  [[ $(installed "$adsp") == first-adsp && ! -e $rerun/firmware/updates/$dtb ]]
  [[ ! -e $TEST_SCAN_LOG ]]
  echo "ok - -d replaces the stage and the Windows partitions"

  # After a full-disk install the stage is the only copy, even when a later
  # device tree names a staged image under another path.
  moved="$rerun/moved-stage"
  old_adsp="qcom/glymur/vendor/old-board/qcadsp.mbn"
  mkdir -p "$moved/${old_adsp%/*}" "$moved/${dtb%/*}"
  printf 'moved-adsp' >"$moved/$old_adsp"
  printf 'staged-dtb' >"$moved/$dtb"
  printf '%s 0 test\n%s 0 test\n' "$old_adsp" "$dtb" >"$moved/manifest"
  reset_installed
  run_rerun --install --no-rebuild --stage-dir "$moved"
  [[ $(installed "$adsp") == windows-adsp && $(installed "$dtb") == staged-dtb ]]
  reset_installed
  TEST_NO_WINDOWS=1 run_rerun --install --no-rebuild --stage-dir "$moved"
  [[ -s $TEST_SCAN_LOG ]]
  [[ $(installed "$adsp") == moved-adsp && $(installed "$dtb") == staged-dtb ]]
  printf '%s 0 test\n' "$dtb" >"$moved/manifest"
  reset_installed
  TEST_NO_WINDOWS=1 run_rerun --install --no-rebuild --stage-dir "$moved"
  [[ ! -e $rerun/firmware/updates/$adsp ]]
  echo "ok - a staged file under an older device-tree path is used after Windows"

  # The stage does not override Windows refusing ambiguous variants.
  mkdir -p "${windows_store%_1}_2"
  printf 'other-adsp' >"${windows_store%_1}_2/qcadsp.mbn"
  printf '%s 0 test\n%s 0 test\n' "$old_adsp" "$dtb" >"$moved/manifest"
  reset_installed
  run_rerun --install --no-rebuild --stage-dir "$moved" 2>"$rerun/warnings"
  grep -Fq "refusing ambiguous qcadsp.mbn" "$rerun/warnings"
  [[ ! -e $rerun/firmware/updates/$adsp && $(installed "$dtb") == staged-dtb ]]
  rm -r "${windows_store%_1}_2"
  echo "ok - a staged file by name does not replace a refused ambiguous match"

  # An installed system reads only internal disks; --stage, in the live
  # session, also reads removable and external ones. The disks: a USB stick,
  # a removable card that is neither USB nor hotplug, an internal disk whose
  # TRAN lsblk leaves empty, and a hotplug NVMe disk.
  (
    export TEST_WINDOWS="$rerun/disks"
    export TEST_PARTITIONS=$'/dev/sda1|ntfs|usb|1|0\n/dev/mmcblk0p1|ntfs|mmc|1|0\n/dev/nvme0n1p3|ntfs||0|0\n/dev/nvme1n1p3|ntfs|nvme|0|1'
    external=(sda1 mmcblk0p1 nvme1n1p3)
    inf="Windows/System32/DriverStore/FileRepository/adsp.inf_1"
    mkdir -p "$TEST_WINDOWS"/{sda1,mmcblk0p1,nvme0n1p3,nvme1n1p3}/"$inf"
    printf 'internal-adsp' >"$TEST_WINDOWS/nvme0n1p3/$inf/qcadsp.mbn"
    for disk in "${external[@]}"; do
      printf 'external-dtb' >"$TEST_WINDOWS/$disk/$inf/adsp_dtbs.elf"
    done
    reset_installed
    output=$(run_rerun --install --no-rebuild)
    [[ $(installed "$adsp") == internal-adsp && ! -e $rerun/firmware/updates/$dtb ]]
    [[ $output == *"not reading removable or external disk partition(s): /dev/sda1 /dev/mmcblk0p1 /dev/nvme1n1p3;"* ]]
    for disk in "${external[@]}"; do
      if grep -qx "mount /dev/$disk" "$TEST_SCAN_LOG"; then
        echo "not ok - an installed system mounted the removable or external /dev/$disk" >&2
        exit 1
      fi
    done
    reset_installed
    run_rerun --stage "$rerun/all-disks"
    [[ $(<"$rerun/all-disks/$adsp") == internal-adsp && $(<"$rerun/all-disks/$dtb") == external-dtb ]]
    for disk in nvme0n1p3 "${external[@]}"; do
      grep -qx "mount /dev/$disk" "$TEST_SCAN_LOG"
    done
  )
  echo "ok - an installed system reads only internal disks, the live session all"
)

# A board package can list firmware names that must not come from Windows.
board="$scratch/board"
board_dt="$board/device-tree"
provided_dir="$board/provided.d"
router="qcom/glymur/vendor/board/usb4-router.bin"
mkdir -p "$board_dt/remoteproc@0" "$board_dt/usb4@0" "$board/store" "$board/root" "$provided_dir"
printf 'vendor,board\0qcom,glymur\0' >"$board_dt/compatible"
printf '%s\0%s\0' "$adsp" "$dtb" >"$board_dt/remoteproc@0/firmware-name"
printf '%s\0' "$router" >"$board_dt/usb4@0/firmware-name"
printf 'store-adsp' >"$board/store/qcadsp.mbn"
printf 'store-dtb' >"$board/store/adsp_dtbs.elf"
printf 'store-router' >"$board/store/usb4-router.bin"

# Runs the extractor through any command in $board_wrapper.
board_wrapper=()
run_board() {
  QCOM_FW_DT_ROOT="$board_dt" \
    QCOM_FW_FIRMWARE_ROOT="$board/firmware" \
    QCOM_FW_ROOT="$board/root" \
    QCOM_FW_TEST_EUID=0 \
    QCOM_FW_PROVIDED_DIR="$provided_dir" \
    PATH="$test_bin:$PATH" \
    "${board_wrapper[@]}" bash "$extractor" "$@"
}
expected_missing=$(printf '%s\n' "$adsp" "$dtb")

[[ $(run_board --list-missing) == "$expected_missing"$'\n'"$router" ]]
printf '# Made by the board package from the Windows driver.\n  %s  # router image\n\n' "$router" \
  >"$provided_dir/other,board.list"
[[ $(run_board --list-missing) == "$expected_missing"$'\n'"$router" ]]
# A compatible string names a list in provided.d, never one in a subdirectory.
cp "$board_dt/compatible" "$board/compatible.saved"
printf 'vendor/board\0' >"$board_dt/compatible"
mkdir -p "$provided_dir/vendor"
printf '%s\n' "$router" >"$provided_dir/vendor/board.list"
[[ $(run_board --list-missing) == "$expected_missing"$'\n'"$router" ]]
mv "$board/compatible.saved" "$board_dt/compatible"
rm -r "$provided_dir/vendor"
echo "ok - firmware listed for another board, or under a path, is still reported missing"

mv "$provided_dir/other,board.list" "$provided_dir/vendor,board.list"
[[ $(run_board --list-missing) == "$expected_missing" ]]
run_board --stage "$board/stage" -d "$board/store"
[[ -f $board/stage/$adsp && ! -e $board/stage/$router ]]
[[ $(grep -c . "$board/stage/manifest") == 2 ]]
run_board --install --no-rebuild -d "$board/store"
[[ $(<"$board/firmware/updates/$adsp") == store-adsp && ! -e $board/firmware/updates/$router ]]
if grep -Fq "$router" "$board/root/var/lib/omarchy/qcom-firmware/manifest"; then
  echo "not ok - provided firmware is recorded as extracted" >&2
  exit 1
fi
[[ -z $(run_board --list-missing) ]]
echo "ok - listed firmware is neither searched for, installed nor reported missing"

# List syntax: a '#' is a comment only at the start of a line or after a space,
# and an entry with a space inside is skipped with a warning, not joined up.
board_list="$provided_dir/vendor,board.list"
cp "$board_list" "$board/list.saved"
printf '%s\n' "${router%/*}/usb4- router.bin" "$router#2" >"$board_list"
[[ $(run_board --list-missing 2>"$board/warnings") == "$router" ]]
grep -Fq "ignoring '${router%/*}/usb4- router.bin' in $board_list" "$board/warnings"
printf '\t%s\t# router image\r\n' "$router" >"$board_list"
[[ -z $(run_board --list-missing) ]]
echo "ok - list comments need a space before '#', and names with spaces are skipped"

# Root reads any file, so as root (CI runs these tests in a root container)
# run without the capabilities that let it.
unreadable_skip=""
if ((EUID == 0)); then
  board_wrapper=(setpriv '--bounding-set=-dac_override,-dac_read_search'
    '--inh-caps=-dac_override,-dac_read_search' --)
  if ! "${board_wrapper[@]}" true 2>/dev/null; then
    unreadable_skip="root can read it, and setpriv could not drop that capability"
  fi
fi
chmod 000 "$board_list"
if [[ -z $unreadable_skip ]] && "${board_wrapper[@]}" cat "$board_list" >/dev/null 2>&1; then
  unreadable_skip="this user can still read a mode 000 file"
fi
if [[ -z $unreadable_skip ]]; then
  output=$(run_board --list-missing 2>"$board/warnings")
fi
board_wrapper=()
chmod 644 "$board_list"
if [[ -z $unreadable_skip ]]; then
  [[ $output == "$router" ]]
  grep -Fq "ignoring $board_list: it cannot be read" "$board/warnings"
  echo "ok - an unreadable list is skipped with a warning"
else
  echo "ok - an unreadable list is skipped with a warning # SKIP $unreadable_skip"
fi
cp "$board/list.saved" "$board_list"

# A copy an earlier run installed before the name was listed is left in place,
# with a note, and no longer recorded. It is never removed, even with the same
# bytes, because a board's own tool may have written that file.
board_manifest="$board/root/var/lib/omarchy/qcom-firmware/manifest"
board_updates="$board/firmware/updates"
install_unlisted_router() {
  rm -f "$board_updates/$router"
  mv "$board_list" "$board/list.off"
  run_board --install --no-rebuild -d "$board/store" >/dev/null
  mv "$board/list.off" "$board_list"
  [[ $(<"$board_updates/$router") == store-router ]]
  grep -q "^$router " "$board_manifest"
}
install_listed_router() {
  local output
  output=$(run_board --install --no-rebuild -d "$board/store")
  [[ $(<"$board_updates/$router") == store-router ]]
  [[ $output == *"note: an earlier run installed $board_updates/$router, but $router is now listed in $board_list; the file is left in place and no longer recorded"* ]]
  if grep -q "^$router " "$board_manifest"; then
    echo "not ok - a listed name is still recorded as installed" >&2
    exit 1
  fi
}
install_unlisted_router
install_listed_router
[[ $(<"$board_updates/$adsp") == store-adsp ]]
install_unlisted_router
# The board's tool writes the same bytes there as a new file.
rm "$board_updates/$router"
printf 'store-router' >"$board_updates/$router"
install_listed_router
rm "$board_updates/$router"
echo "ok - a listed name's earlier copy is left in place and no longer recorded"

# A board also lists names nothing in Windows should supply: SOCCP firmware
# the machine's boot firmware loads before Linux, which no driver store holds,
# and a CDSP image the board holds back although Windows and the stage have it.
soccp="qcom/glymur/vendor/board/soccp.mbn"
soccp_dtb="qcom/glymur/vendor/board/soccp_dtb.mbn"
cdsp="qcom/glymur/vendor/board/qccdsp.mbn"
cdsp_dtb="qcom/glymur/vendor/board/cdsp_dtbs.elf"
board_store="$board/windows/nvme0n1p3/Windows/System32/DriverStore/FileRepository"
mkdir -p "$board_dt/remoteproc@1" "$board_dt/remoteproc@2" "$board/root/run" \
  "$board_store/cdsp.inf_1" "$board_store/adsp.inf_1"
printf '%s\0%s\0' "$soccp" "$soccp_dtb" >"$board_dt/remoteproc@1/firmware-name"
printf '%s\0%s\0' "$cdsp" "$cdsp_dtb" >"$board_dt/remoteproc@2/firmware-name"
printf 'windows-cdsp' >"$board_store/cdsp.inf_1/qccdsp.mbn"
printf 'windows-cdsp-dtb' >"$board_store/cdsp.inf_1/cdsp_dtbs.elf"
printf 'windows-adsp' >"$board_store/adsp.inf_1/qcadsp.mbn"
printf '%s\n' "# Loaded by the boot firmware." "$soccp" "$soccp_dtb" \
  "# Not tested on this board." "$cdsp" "$cdsp_dtb" >>"$board_list"
cdsp_stage="$board/cdsp-stage"
mkdir -p "$cdsp_stage/${cdsp%/*}"
printf 'staged-cdsp' >"$cdsp_stage/$cdsp"
printf 'staged-cdsp-dtb' >"$cdsp_stage/$cdsp_dtb"
printf '%s 0 test\n%s 0 test\n' "$cdsp" "$cdsp_dtb" >"$cdsp_stage/manifest"

(
  stub_windows_partition "$board/windows" "$board/scan.log"

  [[ -z $(run_board --list-missing) ]]
  output=$(run_board --stage "$board/later-stage")
  [[ $output == *"already installed or listed for this board"* && ! -e $board/later-stage ]]
  output=$(run_board --install --no-rebuild)
  [[ $output == *"skipping $soccp: listed in $board_list"* ]]
  run_board --install --no-rebuild --stage-dir "$cdsp_stage"
  [[ ! -e $TEST_SCAN_LOG ]]
  [[ ! -e $board_updates/$soccp && ! -e $board_updates/$cdsp && ! -e $board_updates/$cdsp_dtb ]]
  echo "ok - with only listed names left, nothing reads the disks or installs them"

  # Control: without the list, the same machine looks for them on the disks.
  mv "$board_list" "$board/list.off"
  [[ $(run_board --list-missing | grep -c .) == 5 ]]
  run_board --install --no-rebuild --stage-dir "$cdsp_stage"
  grep -qx lsblk "$TEST_SCAN_LOG"
  grep -qx 'mount /dev/nvme0n1p3' "$TEST_SCAN_LOG"
  [[ $(<"$board_updates/$cdsp") == staged-cdsp ]]
  echo "ok - without the list, the same machine scans the disks for them (control)"

  # Listing them again, without a scan, stops recording the copies that run
  # installed and leaves them in place with a note.
  mv "$board/list.off" "$board_list"
  rm "$TEST_SCAN_LOG"
  output=$(run_board --install --no-rebuild --stage-dir "$cdsp_stage")
  [[ ! -e $TEST_SCAN_LOG ]]
  [[ $(<"$board_updates/$cdsp") == staged-cdsp && $(<"$board_updates/$cdsp_dtb") == staged-cdsp-dtb ]]
  [[ $output == *"note: an earlier run installed $board_updates/$cdsp,"* ]]
  [[ $output == *"note: an earlier run installed $board_updates/$cdsp_dtb,"* ]]
  if grep -qe "^$cdsp " -e "^$cdsp_dtb " "$board_manifest"; then
    echo "not ok - listed names are still recorded as installed" >&2
    exit 1
  fi
  # The board package or the user removes them.
  rm "$board_updates/$cdsp" "$board_updates/$cdsp_dtb"
  echo "ok - listing the names again leaves the copies that run installed, unrecorded"

  # Something else missing still sends the extractor to Windows, for it alone.
  rm "$board_updates/$adsp"
  run_board --install --no-rebuild --stage-dir "$cdsp_stage"
  grep -qx lsblk "$TEST_SCAN_LOG"
  [[ $(<"$board_updates/$adsp") == windows-adsp ]]
  [[ ! -e $board_updates/$soccp && ! -e $board_updates/$cdsp && ! -e $board_updates/$cdsp_dtb ]]
  echo "ok - while Windows is read for other firmware, listed names are not installed"
)
