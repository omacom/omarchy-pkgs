#!/bin/bash
# shellcheck disable=SC2030,SC2031
set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
install_script="$package_dir/dell-xps13-sidecar-amps.install"
apply_script="$package_dir/dell-xps13-sidecar-amps-apply"
scratch=$(mktemp -d)
current_case="setup"
trap 'rm -rf "$scratch"' EXIT
trap 'echo "not ok - ${current_case} (line ${LINENO})" >&2' ERR

make_stub() {
  printf '#!/bin/bash\n%s\n' "$3" >"$1/$2"
  chmod +x "$1/$2"
}

assert_no_match() {
  local pattern=$1 file=$2 rc=0
  [[ -f $file ]] || { printf 'missing log: %s\n' "$file" >&2; return 1; }
  grep -Eq "$pattern" "$file" || rc=$?
  (( rc == 1 )) || { printf 'unexpected match or grep error (rc=%d) for %s in %s\n' "$rc" "$pattern" "$file" >&2; return 1; }
}

setup_env() {
  work="$scratch/$1"; bin="$work/bin"; calls="$work/calls"
  mkdir -p "$bin" "$work/run-systemd" "$work/etc/pacman.d/hooks" "$work/usr/share/libalpm/hooks"
  make_stub "$bin" systemd-detect-virt 'exit 1'
  make_stub "$bin" ischroot 'exit 1'
  make_stub "$bin" limine-mkinitcpio "printf 'limine-mkinitcpio\n' >>\"$calls\""
  make_stub "$bin" mkinitcpio "printf 'mkinitcpio %s\n' \"\$*\" >>\"$calls\""
  make_stub "$bin" apply-stub "printf 'apply %s\n' \"\$*\" >>\"$calls\""
}

run_lifecycle() {
  local systemd_dir=$1 etc_hook=$2 usr_hook=$3
  shift 3
  (
    export PATH="$bin:/usr/bin:/bin"
    # shellcheck source=/dev/null
    source "$install_script"
    _apply_command="$bin/apply-stub"
    _systemd_runtime_dir="$systemd_dir"
    _etc_mkinitcpio_hook="$etc_hook"
    _usr_mkinitcpio_hook="$usr_hook"
    for fn in "$@"; do "$fn" >/dev/null; done
  )
}

run_case() { current_case=$1; shift; "$@"; echo "ok - $current_case"; }

case_checksums() {
  (
    source=(); sha256sums=()
    # shellcheck source=/dev/null
    source "$package_dir/PKGBUILD"
    (( ${#source[@]} == ${#sha256sums[@]} )) || exit 1
    for i in "${!source[@]}"; do
      [[ ${source[i]} == *://* ]] && continue
      actual=$(sha256sum "$package_dir/${source[i]}" | cut -d" " -f1)
      [[ $actual == "${sha256sums[i]}" ]] || { printf 'checksum mismatch for %s\n' "${source[i]}" >&2; exit 1; }
    done
  )
}

case_chroot_and_offline_skip_rebuild() {
  # systemd-detect-virt -r
  setup_env chroot
  # shellcheck disable=SC2016
  make_stub "$bin" systemd-detect-virt '[[ ${1:-} == -r ]] && exit 0; exit 1'
  run_lifecycle "$work/run-systemd" "$work/no-etc" "$work/no-usr" post_install post_upgrade post_remove
  [[ $(grep -cFx "apply --no-rebuild" "$calls") -eq 2 ]]
  assert_no_match "^(limine-mkinitcpio|mkinitcpio)" "$calls"

  # ischroot fallback
  setup_env ischroot
  make_stub "$bin" ischroot 'exit 0'
  run_lifecycle "$work/run-systemd" "$work/no-etc" "$work/no-usr" post_install post_remove
  grep -Fxq "apply --no-rebuild" "$calls"
  assert_no_match "^(limine-mkinitcpio|mkinitcpio)" "$calls"

  # missing /run/systemd/system
  setup_env no-systemd
  run_lifecycle "$work/missing-systemd" "$work/no-etc" "$work/no-usr" post_install post_remove
  grep -Fxq "apply --no-rebuild" "$calls"
  assert_no_match "^(limine-mkinitcpio|mkinitcpio)" "$calls"
}

case_masked_hook_skips_rebuild() {
  setup_env masked
  local hook="$work/etc/pacman.d/hooks/90-mkinitcpio-install.hook"
  ln -s /dev/null "$hook"
  run_lifecycle "$work/run-systemd" "$hook" "$work/no-usr" post_install post_remove
  rm -f "$hook"; : >"$hook"
  run_lifecycle "$work/run-systemd" "$hook" "$work/no-usr" post_upgrade post_remove
  [[ $(grep -cFx "apply --no-rebuild" "$calls") -eq 2 ]]
  assert_no_match "^(limine-mkinitcpio|mkinitcpio)" "$calls"
}

case_hook_watching_modprobe_per_operation() {
  setup_env hook-ops
  local usr_hook="$work/usr/share/libalpm/hooks/90-mkinitcpio-install.hook"
  local etc_hook="$work/etc/pacman.d/hooks/90-mkinitcpio-install.hook"

  # Stock hook covering Install/Upgrade/Remove avoids duplicate rebuilds.
  printf '[Trigger]\nType = Path\nOperation = Install\nOperation = Upgrade\nOperation = Remove\nTarget = usr/lib/modprobe.d/\n\n[Action]\nWhen = PostTransaction\nExec = /usr/share/libalpm/scripts/mkinitcpio install\n' >"$usr_hook"
  run_lifecycle "$work/run-systemd" "$work/no-etc" "$usr_hook" post_install post_upgrade post_remove
  [[ $(grep -cFx "apply --no-rebuild" "$calls") -eq 2 ]]
  assert_no_match "^(limine-mkinitcpio|mkinitcpio)" "$calls"

  # Hook omitting Remove still rebuilds on post_remove.
  : >"$calls"
  printf '[Trigger]\nType = Path\nOperation = Install\nOperation = Upgrade\nTarget = usr/lib/modprobe.d/\n\n[Action]\nWhen = PostTransaction\nExec = /usr/share/libalpm/scripts/mkinitcpio install\n' >"$etc_hook"
  run_lifecycle "$work/run-systemd" "$etc_hook" "$work/no-usr" post_install post_remove
  grep -Fxq "apply --no-rebuild" "$calls"
  grep -Fxq "limine-mkinitcpio" "$calls"

  # Missing trailing slash, negated target, PreTransaction, or non-rebuilder Exec must NOT suppress rebuilds.
  for bad_hook in \
    $'[Trigger]\nType = Path\nOperation = Install\nOperation = Remove\nTarget = usr/lib/modprobe.d\n\n[Action]\nWhen = PostTransaction\nExec = /usr/share/libalpm/scripts/mkinitcpio install\n' \
    $'[Trigger]\nType = Path\nOperation = Install\nOperation = Remove\nTarget = usr/lib/modprobe.d/*\nTarget = !usr/lib/*\n\n[Action]\nWhen = PostTransaction\nExec = /usr/share/libalpm/scripts/mkinitcpio install\n' \
    $'[Trigger]\nType = Path\nOperation = Install\nOperation = Remove\nTarget = usr/lib/modprobe.d/\n\n[Action]\nWhen = PreTransaction\nExec = /usr/share/libalpm/scripts/mkinitcpio install\n' \
    $'[Trigger]\nType = Path\nOperation = Install\nOperation = Remove\nTarget = usr/lib/modprobe.d/\n\n[Action]\nWhen = PostTransaction\nExec = /usr/bin/true mkinitcpio\n' \
    $'[Trigger]\nType = Path\nOperation = Install\nOperation = Remove\nTarget = usr/lib/modprobe.d/\n\n[Action]\nWhen = PostTransaction\nExec = /usr/bin/omarchy-boot-rebuild --pacman-remove\n'; do
    : >"$calls"
    printf '%s' "$bad_hook" >"$etc_hook"
    run_lifecycle "$work/run-systemd" "$etc_hook" "$work/no-usr" post_install post_remove
    grep -Fxq "apply " "$calls"
    grep -Fxq "limine-mkinitcpio" "$calls"
  done
}

case_live_limine_rebuilds_and_fallback() {
  setup_env live-limine
  local etc_hook="$work/etc/pacman.d/hooks/90-mkinitcpio-install.hook"
  local usr_hook="$work/usr/share/libalpm/hooks/90-mkinitcpio-install.hook"
  printf '[Trigger]\nType = Path\nOperation = Install\nOperation = Upgrade\nOperation = Remove\nTarget = usr/lib/firmware/*\n\n[Action]\nWhen = PostTransaction\nExec = /usr/share/libalpm/scripts/limine-mkinitcpio-install\n' >"$etc_hook"
  printf '[Trigger]\nType = Path\nOperation = Install\nOperation = Upgrade\nOperation = Remove\nTarget = usr/lib/modprobe.d/\n\n[Action]\nWhen = PostTransaction\nExec = /usr/share/libalpm/scripts/mkinitcpio install\n' >"$usr_hook"

  run_lifecycle "$work/run-systemd" "$etc_hook" "$usr_hook" post_install post_upgrade post_remove
  [[ $(grep -cFx "apply " "$calls") -eq 2 ]]
  grep -Fxq "limine-mkinitcpio" "$calls"

  # Masked per-kernel ERROR line in limine-mkinitcpio fails non-zero.
  make_stub "$bin" limine-mkinitcpio 'echo "ERROR: failed to build UKI"; exit 0'
  local rc=0
  (
    export PATH="$bin:/usr/bin:/bin"
    # shellcheck source=/dev/null
    source "$install_script"
    _systemd_runtime_dir="$work/run-systemd"
    _etc_mkinitcpio_hook="$etc_hook"
    _usr_mkinitcpio_hook="$work/no-usr"
    post_remove >/dev/null
  ) || rc=$?
  (( rc != 0 ))

  # Fallback to mkinitcpio -P when limine-mkinitcpio is absent (isolated from host PATH).
  rm -f "$bin/limine-mkinitcpio"
  (
    export PATH="$bin:/usr/bin:/bin"
    # shellcheck disable=SC2329
    command() { [[ ${1:-} == -v && ${2:-} == limine-mkinitcpio ]] && return 1; builtin command "$@"; }
    # shellcheck source=/dev/null
    source "$install_script"
    _systemd_runtime_dir="$work/run-systemd"
    _etc_mkinitcpio_hook="$etc_hook"
    _usr_mkinitcpio_hook="$work/no-usr"
    post_remove >/dev/null
  )
  grep -Fxq "mkinitcpio -P" "$calls"
}

case_apply_no_rebuild() {
  setup_env apply-no-rebuild
  mkdir -p "$work/etc/modprobe.d"
  printf 'options snd_soc_sof_sdw quirk=65536\n' >"$work/etc/modprobe.d/legacy.conf"
  local sum
  sum=$(sha256sum "$work/etc/modprobe.d/legacy.conf" | cut -d" " -f1)

  (
    export PATH="$bin:/usr/bin:/bin"
    # shellcheck source=/dev/null
    source "$apply_script"
    _legacy_override="$work/etc/modprobe.d/legacy.conf"
    _legacy_sha256="$sum"
    apply_sidecar_amp_workaround --no-rebuild >/dev/null
  )
  [[ ! -e $work/etc/modprobe.d/legacy.conf && ! -e $calls ]]

  printf 'options snd_soc_sof_sdw quirk=12345\n' >"$work/etc/modprobe.d/legacy.conf"
  (
    export PATH="$bin:/usr/bin:/bin"
    # shellcheck source=/dev/null
    source "$apply_script"
    _legacy_override="$work/etc/modprobe.d/legacy.conf"
    _legacy_sha256="$sum"
    apply_sidecar_amp_workaround --no-rebuild >/dev/null
  )
  [[ -f $work/etc/modprobe.d/legacy.conf && ! -e $calls ]]

  # Direct apply also respects a masked 90-mkinitcpio-install.hook.
  ln -s /dev/null "$work/etc/pacman.d/hooks/90-mkinitcpio-install.hook"
  (
    export PATH="$bin:/usr/bin:/bin"
    # shellcheck source=/dev/null
    source "$apply_script"
    _legacy_override="$work/etc/modprobe.d/legacy.conf"
    _legacy_sha256="$sum"
    _etc_mkinitcpio_hook="$work/etc/pacman.d/hooks/90-mkinitcpio-install.hook"
    apply_sidecar_amp_workaround >/dev/null
  )
  [[ ! -e $calls ]]
}

run_case "PKGBUILD local source checksums match disk" case_checksums
run_case "chroot (systemd-detect-virt -r, ischroot) and offline skip boot-image rebuild" case_chroot_and_offline_skip_rebuild
run_case "masked 90-mkinitcpio-install.hook skips boot-image rebuild" case_masked_hook_skips_rebuild
run_case "active mkinitcpio hook watches modprobe.d per PostTransaction operation" case_hook_watching_modprobe_per_operation
run_case "live limine-mkinitcpio-hook rebuilds, propagates ERROR, and falls back to mkinitcpio" case_live_limine_rebuilds_and_fallback
run_case "apply --no-rebuild migrates exact legacy override without rebuilding" case_apply_no_rebuild
