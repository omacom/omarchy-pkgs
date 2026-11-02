#!/bin/bash
set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export OMARCHY_KERNEL_SHIM_ROOT=$scratch
export SHIM_NATIVE=0 SHIM_KERNEL_PRESENT=1
export SHIM_IMAGE_OWNER=linux-aarch64
export SHIM_DIR_OWNERS=linux-aarch64

pacman() {
  if [[ $1 == -Qlq ]]; then
    printf '/usr/lib/initcpio/install/test\n'
    return 0
  fi
  case $2 in
    /boot/Image)
      printf '%s\n' "$SHIM_IMAGE_OWNER"
      ;;
    /usr/lib/modules/test)
      ((SHIM_KERNEL_PRESENT)) || return 1
      printf '%s\n' "$SHIM_DIR_OWNERS"
      ;;
    /usr/lib/modules/test/pkgbase | /usr/lib/modules/test/vmlinuz)
      [[ $SHIM_NATIVE == 1 || $2 == /usr/lib/modules/test/"$SHIM_NATIVE" ]] || return 1
      printf 'linux-aarch64\n'
      ;;
    *) return 1 ;;
  esac
}
export -f pacman

modules=$scratch/usr/lib/modules/test
mkdir -p "$modules" "$scratch/boot" "$scratch/etc/pacman.d/hooks" \
  "$scratch/usr/share/libalpm/scripts"
printf 'first-kernel' >"$scratch/boot/Image"
cat >"$scratch/usr/share/libalpm/scripts/limine-mkinitcpio-install" <<'SCRIPT'
#!/bin/bash
cat >>"$OMARCHY_KERNEL_SHIM_ROOT/rebuilds"
SCRIPT
chmod +x "$scratch/usr/share/libalpm/scripts/limine-mkinitcpio-install"

run_shim() {
  printf '%s\n' "$1" | bash "$package_dir/linux-aarch64-pkgbase-shim"
}

run_shim usr/lib/modules/test/
[[ $(<"$modules/pkgbase") == linux-aarch64 ]]
cmp "$scratch/boot/Image" "$modules/vmlinuz"
[[ $(stat -c %a "$modules/vmlinuz") == $(stat -c %a "$scratch/boot/Image") ]]
[[ ! -e $scratch/rebuilds ]]
echo 'ok - kernel installation supplies metadata before the normal rebuild hook'

for SHIM_DIR_OWNERS in $'linux-aarch64\nlinux-aarch64-headers' \
  $'linux-aarch64-headers\nlinux-aarch64'; do
  rm "$modules/pkgbase" "$modules/vmlinuz"
  run_shim usr/lib/modules/test/
  [[ $(<"$modules/pkgbase") == linux-aarch64 ]]
  cmp "$scratch/boot/Image" "$modules/vmlinuz"
done
echo 'ok - shared kernel and headers directories use the image owner in either order'
SHIM_DIR_OWNERS=linux-aarch64

printf 'replacement-kernel' >"$scratch/boot/Image"
run_shim usr/lib/modules/test/
cmp "$scratch/boot/Image" "$modules/vmlinuz"
echo 'ok - reinstalling the same kernel version refreshes its image'

printf 'shim-upgrade' >"$scratch/boot/Image"
run_shim linux-aarch64-pkgbase-shim
[[ $(<"$scratch/rebuilds") == rebuild ]]
run_shim linux-aarch64-pkgbase-shim
[[ $(wc -l <"$scratch/rebuilds") == 1 ]]
echo 'ok - unchanged images do not trigger redundant rebuilds'

ln -s /dev/null "$scratch/etc/pacman.d/hooks/90-mkinitcpio-install.hook"
printf 'deferred-kernel' >"$scratch/boot/Image"
run_shim linux-aarch64-pkgbase-shim
cmp "$scratch/boot/Image" "$modules/vmlinuz"
[[ $(wc -l <"$scratch/rebuilds") == 1 ]]
echo 'ok - the installer can defer boot-image regeneration'

for SHIM_NATIVE in pkgbase vmlinuz; do
  printf 'package-owned' >"$modules/vmlinuz"
  run_shim usr/lib/modules/test/
  [[ $(<"$modules/vmlinuz") == package-owned ]]
done
echo 'ok - either package-owned metadata file prevents replacement'

SHIM_NATIVE=0
SHIM_IMAGE_OWNER=another-kernel
run_shim usr/lib/modules/test/
[[ $(<"$modules/vmlinuz") == package-owned ]]
SHIM_IMAGE_OWNER=linux-aarch64
echo 'ok - a different kernel image owner prevents replacement'

SHIM_DIR_OWNERS=linux-aarch64-headers
run_shim usr/lib/modules/test/
[[ $(<"$modules/vmlinuz") == package-owned ]]
SHIM_DIR_OWNERS=$'linux-aarch64\nlinux-aarch64-headers'
SHIM_IMAGE_OWNER=$'linux-aarch64\nlinux-aarch64-headers'
run_shim usr/lib/modules/test/
[[ $(<"$modules/vmlinuz") == package-owned ]]
SHIM_DIR_OWNERS=linux-aarch64
SHIM_IMAGE_OWNER=linux-aarch64
echo 'ok - headers-only directories and ambiguous image ownership prevent replacement'

printf 'another-kernel\n' >"$modules/pkgbase"
run_shim usr/lib/modules/test/ 2>"$scratch/warning"
[[ $(<"$modules/vmlinuz") == package-owned ]]
grep -Fq 'pkgbase does not name linux-aarch64' "$scratch/warning"
printf 'linux-aarch64\n' >"$modules/pkgbase"
echo 'ok - a pkgbase naming another package is reported and preserved'

(
  # shellcheck disable=SC2329 # Invoked by the shim in a child shell.
  cp() { return 1; }
  export -f cp
  if run_shim usr/lib/modules/test/; then
    echo 'not ok - a failed image copy was accepted' >&2
    exit 1
  fi
  [[ $(<"$modules/vmlinuz") == package-owned ]]
)
echo 'ok - failed copies preserve the previous kernel image'

SHIM_KERNEL_PRESENT=0
mkdir -p "$modules/updates/dkms"
run_shim usr/lib/modules/test/
[[ -d $modules/updates/dkms && -f $modules/vmlinuz ]]
rmdir "$modules/updates/dkms" "$modules/updates"
echo 'ok - kernel removal preserves DKMS leftovers'
run_shim usr/lib/modules/test/
[[ ! -d $modules ]]
echo 'ok - kernel removal cleans up leftover shim metadata'
