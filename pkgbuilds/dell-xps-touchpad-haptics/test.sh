#!/bin/bash
# shellcheck disable=SC2030,SC2031
set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
install_script="$package_dir/dell-xps-touchpad-haptics.install"
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
  mkdir -p "$bin" "$work/units" "$work/etc"
  touch "$work/units/dell-xps-touchpad-haptics.service"
  make_stub "$bin" systemctl "printf 'systemctl %s\n' \"\$*\" >>\"$calls\""
  make_stub "$bin" udevadm "printf 'udevadm %s\n' \"\$*\" >>\"$calls\""
  make_stub "$bin" omarchy-restart-trackpad "printf 'restart-trackpad\n' >>\"$calls\""
  make_stub "$bin" runuser "printf 'runuser %s\n' \"\$*\" >>\"$calls\""
}

run_install() {
  local fn=$1 systemd_dir=$2
  (
    export PATH="$bin:/usr/bin:/bin"
    # shellcheck source=/dev/null
    source "$install_script"
    _env_path="$work/etc/dell-xps-touchpad-haptics.env"
    _legacy_env_path="$work/etc/omarchy-dell-haptic-touchpad.env"
    _legacy_override_dir="$work/etc/legacy.d"
    _service_unit_dir="$work/units"
    _systemd_runtime_dir="$systemd_dir"
    _udev_control_socket="$work/no-udev"
    _runuser_path="$bin/runuser"
    "$fn"
  )
}

run_case() { current_case=$1; shift; "$@"; echo "ok - $current_case"; }

case_chroot_no_user() {
  setup_env chroot-no-user
  # shellcheck disable=SC2016
  make_stub "$bin" systemd-detect-virt '[[ ${1:-} == -r ]] && exit 0; exit 1'
  make_stub "$bin" getent 'printf "root:x:0:0:root:/root:/bin/bash\nnobody:x:65534:65534:Nobody:/:/usr/bin/nologin\n"'
  make_stub "$bin" logname "printf 'logname\n' >>\"$calls\"; echo hostuser"
  make_stub "$bin" loginctl "printf 'loginctl\n' >>\"$calls\"; echo '1000 hostuser seat0 active'"

  out=$(unset OMARCHY_HAPTIC_USER OMARCHY_INSTALL_USER SUDO_USER; run_install post_install "$work/run-systemd" 2>&1)
  [[ $out == *"will start on next boot"* && $out == *"Reinstall dell-xps-touchpad-haptics"* ]]
  grep -Fxq "systemctl --root=/ enable dell-xps-touchpad-haptics.service" "$calls"
  assert_no_match "^(systemctl (daemon-reload|restart)|udevadm|restart-trackpad|runuser|logname|loginctl)" "$calls"
  [[ ! -e $work/etc/dell-xps-touchpad-haptics.env ]]
}

case_ischroot_no_user() {
  setup_env ischroot-no-user
  mkdir -p "$work/run-systemd"
  make_stub "$bin" systemd-detect-virt 'exit 1'
  make_stub "$bin" ischroot 'exit 0'
  make_stub "$bin" getent 'printf "root:x:0:0:root:/root:/bin/bash\n"'

  (unset OMARCHY_HAPTIC_USER OMARCHY_INSTALL_USER SUDO_USER; run_install post_upgrade "$work/run-systemd") >/dev/null 2>&1
  grep -Fxq "systemctl --root=/ enable dell-xps-touchpad-haptics.service" "$calls"
  assert_no_match "^(systemctl (daemon-reload|restart)|udevadm|restart-trackpad)" "$calls"
}

case_no_systemd_no_user() {
  setup_env no-systemd
  make_stub "$bin" systemd-detect-virt 'exit 1'
  make_stub "$bin" ischroot 'exit 1'
  make_stub "$bin" getent 'printf "root:x:0:0:root:/root:/bin/bash\n"'
  make_stub "$bin" logname 'exit 1'
  make_stub "$bin" loginctl 'exit 1'

  out=$(unset OMARCHY_HAPTIC_USER OMARCHY_INSTALL_USER SUDO_USER; run_install post_install "$work/missing-systemd" 2>&1)
  [[ $out == *"will start on next boot"* ]]
  grep -Fxq "systemctl --root=/ enable dell-xps-touchpad-haptics.service" "$calls"
  assert_no_match "^(systemctl (daemon-reload|restart)|udevadm|restart-trackpad)" "$calls"
}

case_existing_home_missing_user() {
  setup_env existing-home
  mkdir -p "$work/home/alice"
  printf 'DELL_XPS_TOUCHPAD_HAPTICS_HOME=%s\nDELL_XPS_TOUCHPAD_HAPTICS_DEBUG=1\n' \
    "$work/home/alice" >"$work/etc/dell-xps-touchpad-haptics.env"
  make_stub "$bin" systemd-detect-virt 'exit 0'
  # shellcheck disable=SC2016
  make_stub "$bin" getent '[[ -z ${2:-} ]] && { printf "root:x:0:0:root:/root:/bin/bash\n"; exit 0; }; exit 2'

  (export OMARCHY_INSTALL_USER=ghost; unset OMARCHY_HAPTIC_USER SUDO_USER; run_install post_upgrade "$work/missing") >/dev/null 2>&1
  grep -Fxq "systemctl --root=/ enable dell-xps-touchpad-haptics.service" "$calls"
  assert_no_match "^runuser" "$calls"
  grep -Fxq "DELL_XPS_TOUCHPAD_HAPTICS_HOME=$work/home/alice" "$work/etc/dell-xps-touchpad-haptics.env"
  grep -Fxq "DELL_XPS_TOUCHPAD_HAPTICS_DEBUG=1" "$work/etc/dell-xps-touchpad-haptics.env"
}

case_chroot_install_user() {
  setup_env chroot-user
  local user_home="$work/home/bob"
  mkdir -p "$work/run-systemd" "$user_home"
  make_stub "$bin" systemd-detect-virt 'exit 0'
  make_stub "$bin" getent "if [[ \${2:-} == bob ]]; then printf 'bob:x:1000:1000:Bob:%s:/bin/bash\n' \"$user_home\"; else exit 2; fi"
  make_stub "$bin" runuser "printf 'runuser %s\n' \"\$*\" >>\"$calls\"; mkdir -p \"$user_home/.config/omarchy\"; printf 'INTENSITY=100\n' >\"$user_home/.config/omarchy/dell-haptic.conf\""

  (export OMARCHY_INSTALL_USER=bob; unset OMARCHY_HAPTIC_USER SUDO_USER; run_install post_install "$work/run-systemd") >/dev/null 2>&1
  grep -Fxq "DELL_XPS_TOUCHPAD_HAPTICS_HOME=$user_home" "$work/etc/dell-xps-touchpad-haptics.env"
  grep -Fxq "INTENSITY=100" "$user_home/.config/omarchy/dell-haptic.conf"
  grep -Fxq "systemctl --root=/ enable dell-xps-touchpad-haptics.service" "$calls"
  assert_no_match "^(systemctl (daemon-reload|restart)|restart-trackpad)" "$calls"
}

case_live_normal_install() {
  setup_env live-normal
  local user_home="$work/home/alice"
  mkdir -p "$work/run-systemd" "$user_home"
  make_stub "$bin" systemd-detect-virt 'exit 1'
  make_stub "$bin" ischroot 'exit 1'
  make_stub "$bin" getent "if [[ \${2:-} == alice ]]; then printf 'alice:x:1000:1000:Alice:%s:/bin/bash\n' \"$user_home\"; else printf 'root:x:0:0:root:/root:/bin/bash\nalice:x:1000:1000:Alice:%s:/bin/bash\n' \"$user_home\"; fi"
  make_stub "$bin" logname 'exit 1'
  make_stub "$bin" loginctl 'exit 1'
  make_stub "$bin" runuser "printf 'runuser %s\n' \"\$*\" >>\"$calls\"; mkdir -p \"$user_home/.config/omarchy\"; printf 'INTENSITY=100\n' >\"$user_home/.config/omarchy/dell-haptic.conf\""

  (unset OMARCHY_HAPTIC_USER OMARCHY_INSTALL_USER SUDO_USER; run_install post_install "$work/run-systemd") >/dev/null 2>&1
  grep -Fxq "DELL_XPS_TOUCHPAD_HAPTICS_HOME=$user_home" "$work/etc/dell-xps-touchpad-haptics.env"
  grep -Fxq "INTENSITY=100" "$user_home/.config/omarchy/dell-haptic.conf"
  grep -Fxq "systemctl daemon-reload" "$calls"
  grep -Fxq "systemctl enable dell-xps-touchpad-haptics.service" "$calls"
  grep -Fxq "systemctl restart dell-xps-touchpad-haptics.service" "$calls"
  grep -Fxq "restart-trackpad" "$calls"
}

case_remove_chroot_and_live() {
  setup_env remove-chroot
  mkdir -p "$work/run-systemd"
  touch "$work/etc/dell-xps-touchpad-haptics.env"
  make_stub "$bin" systemd-detect-virt 'exit 0'
  run_install pre_remove "$work/run-systemd"
  run_install post_remove "$work/run-systemd"
  grep -Fxq "systemctl --root=/ disable dell-xps-touchpad-haptics.service" "$calls"
  assert_no_match "^systemctl (stop|daemon-reload)" "$calls"
  [[ ! -e $work/etc/dell-xps-touchpad-haptics.env ]]

  setup_env remove-live
  mkdir -p "$work/run-systemd"
  touch "$work/etc/dell-xps-touchpad-haptics.env"
  make_stub "$bin" systemd-detect-virt 'exit 1'
  make_stub "$bin" ischroot 'exit 1'
  run_install pre_remove "$work/run-systemd"
  run_install post_remove "$work/run-systemd"
  grep -Fxq "systemctl disable dell-xps-touchpad-haptics.service" "$calls"
  grep -Fxq "systemctl stop dell-xps-touchpad-haptics.service" "$calls"
  grep -Fxq "systemctl daemon-reload" "$calls"
  [[ ! -e $work/etc/dell-xps-touchpad-haptics.env ]]
}

run_case "chroot (systemd-detect-virt -r) with no user enables service offline" case_chroot_no_user
run_case "ischroot with no user enables service offline" case_ischroot_no_user
run_case "no running systemd with no user enables service offline and skips trackpad reset" case_no_systemd_no_user
run_case "existing env home with missing user (getent rc=2) preserves env and enables service" case_existing_home_missing_user
run_case "chroot with OMARCHY_INSTALL_USER seeds config and skips runtime restart" case_chroot_install_user
run_case "live desktop install writes env, seeds config, reloads, enables, and starts service" case_live_normal_install
run_case "pre_remove/post_remove use offline disable in chroot and runtime stop/reload live" case_remove_chroot_and_live
