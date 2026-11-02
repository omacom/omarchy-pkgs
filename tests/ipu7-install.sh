#!/bin/bash
set -euo pipefail

REPO_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
CALLS="$TEST_ROOT/calls"

# Exercise the real scriptlet with only system operations and state probes
# substituted. No host files, services, udev state or modules are changed.
script=$(<"$REPO_ROOT/pkgbuilds/intel-ipu7-camera/intel-ipu7-camera.install")
script=${script//\/usr\/bin\/systemd-tmpfiles/fixture_tmpfiles}
script=${script//\/usr\/bin\/udevadm/fixture_udevadm}
source /dev/stdin <<<"$script"

fixture_tmpfiles() {
  printf 'tmpfiles %s\n' "$*" >>"$CALLS"
  [[ $scenario != "tmpfiles-fail" ]]
}
fixture_udevadm() {
  printf 'udev %s\n' "$*" >>"$CALLS"
  case "$scenario:$1" in
    reload-fail:control|trigger-fail:trigger) return 1 ;;
  esac
}
function [() {
  case "$*" in
    '-S /run/udev/control ]') [[ $scenario != "no-udev" ]] ;;
    '-d /sys/module/intel_ipu7_psys ]') [[ $loaded == "yes" ]] ;;
    *) builtin [ "$@" ;;
  esac
}
_install_sleep_hook() { echo sleep-hook >>"$CALLS"; }
_add_pipewire_camera() { printf 'browser %s\n' "$*" >>"$CALLS"; }
systemctl() { printf 'systemctl %s\n' "$*" >>"$CALLS"; }
usermod() { printf 'usermod %s\n' "$*" >>"$CALLS"; }
SUDO_USER=fixture-user

fail() { printf 'FAIL: %s (%s, loaded=%s, %s)\n' "$*" "$hook" "$loaded" "$scenario" >&2; exit 1; }

for hook in post_install post_upgrade; do
  for loaded in yes no; do
    for scenario in reload-fail trigger-fail tmpfiles-fail no-udev success; do
      : >"$CALLS"
      # Pacman scriptlets do not use errexit; a refresh failure must not skip
      # the remaining lifecycle work, including the loaded-driver warning.
      output=$(set +e; "$hook" 2>&1) || fail "scriptlet failed"
      [[ $output != *"restricted device permissions are active"* ]] || fail "unverified permission assurance"
      if [[ $hook == "post_upgrade" && $loaded == "yes" ]]; then
        [[ $output == *"reboot required to activate the updated IPU7 kernel driver"* ]] || fail "missing reboot warning"
      else
        [[ $output != *"reboot required to activate"* ]] || fail "unexpected loaded-driver warning"
      fi
      case "$scenario" in
        tmpfiles-fail) [[ $output == *"failed to restrict /run/camera"* ]] || fail "missing directory warning" ;;
        reload-fail|trigger-fail) [[ $output == *"failed to restrict the IPU7 device"* ]] || fail "missing device warning" ;;
        *) [[ $output != *"WARNING:"* ]] || fail "unexpected refresh warning" ;;
      esac
      grep -qx 'sleep-hook' "$CALLS" || fail "sleep hook skipped"
      grep -qx 'tmpfiles --create /usr/lib/tmpfiles.d/camera.conf' "$CALLS" || fail "permission refresh skipped"
      grep -qx 'systemctl daemon-reload' "$CALLS" || fail "daemon reload skipped"
      grep -qx 'systemctl enable intel-ipu7-camera.service' "$CALLS" || fail "service enable skipped"
      [[ $(grep -c '^browser ' "$CALLS") == 3 ]] || fail "browser lifecycle skipped"
      if [[ $scenario == "no-udev" ]]; then
        ! grep -q '^udev ' "$CALLS" || fail "contacted absent udev"
      else
        grep -qx 'udev control --reload-rules' "$CALLS" || fail "udev reload skipped"
        if [[ $scenario != "reload-fail" ]]; then
          grep -qx 'udev trigger --action=change --sysname-match=ipu7-psys0' "$CALLS" || fail "udev trigger skipped"
        fi
      fi
    done
  done
done

echo 'PASS: 20 IPU7 install/upgrade warning and lifecycle cases'
