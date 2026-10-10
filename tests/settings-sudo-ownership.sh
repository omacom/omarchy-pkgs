#!/bin/bash
# Build real runtime/settings payloads from synthetic old/new source layouts.
# This checks package ownership and a simulated runtime removal; it does not
# substitute for a real pacman upgrade/removal transaction in an Arch VM.
set -euo pipefail
export LC_ALL=C
# Match makepkg's source and payload creation permissions regardless of the
# invoking developer's umask.
umask 022

root=$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
payload_capture=${SETTINGS_SUDO_PAYLOAD_DIR:-}
if [[ -n $payload_capture ]]; then
  mkdir -p "$payload_capture"
  payload_capture=$(realpath "$payload_capture")
fi

fail() {
  printf 'FAIL: %s\n' "$@" >&2
  exit 1
}

# These are the unrelated source inputs the real package functions require.
# They carry no executable behavior; the security payloads below have explicit
# contents so copying the wrong file or dropping a dependency is detectable.
files=(
  applications/example.desktop
  bin/omarchy-debug
  bin/omarchy-debug-idle
  bin/omarchy-hw-platform
  bin/omarchy-upload-log
  bin/omarchy-runtime-probe
  config/autostart/limine-snapper-notify.desktop
  config/hypr/hyprland.lua
  default/applications/mimeapps.list
  default/bashrc
  default/environment.d/10-omarchy-fcitx.conf
  default/fontconfig/conf.avail/50-omarchy.conf
  default/fonts/omarchy/omarchy.ttf
  default/hypr/toggles/flags.lua
  default/libalpm/hooks/00-omarchy-update-guard.hook
  default/libalpm/hooks/10-omarchy-hyprland-reload-pause.hook
  default/libalpm/hooks/90-omarchy-hyprland-reload-resume.hook
  default/limine/default.conf
  default/limine/limine.conf
  default/nautilus-python/extensions/localsend.py
  default/nautilus-python/extensions/transcode.py
  default/plymouth/omarchy.plymouth
  default/sddm/hyprland.lua
  default/sddm/omarchy/Main.qml
  default/snapper/root
  default/systemd/system-sleep/unmount-fuse
  default/systemd/system/plocate-updatedb.service.d/10-omarchy.conf
  default/systemd/user/app.slice.d/10-oomd.conf
  default/systemd/user/bt-agent.service
  default/systemd/user/omarchy-crash-watch.service
  default/systemd/user/omarchy-fcitx5.service
  default/systemd/user/omarchy-migrate-notify.service
  default/systemd/user/omarchy-recover-internal-monitor.service
  default/systemd/user/omarchy-sleep-lock.service
  default/systemd/user/omarchy-tailscale-receive.service
  default/systemd/zram-generator.conf.d/90-omarchy.conf
  default/tensaku/state.toml
  default/uwsm/env.d/10-omarchy
  default/wayland-sessions/omarchy.desktop
  default/xdg-terminal-exec/hyprland-xdg-terminals.list
  etc/cups/cups-browsed.conf
  etc/cups/cups-files.conf
  etc/fastfetch/config.jsonc
  etc/limine-entry-tool.d/omarchy-defaults.conf
  etc/limine-entry-tool.d/omarchy-uki.conf
  etc/mkinitcpio.conf.d/omarchy_hooks.conf
  etc/mkinitcpio.conf.d/thunderbolt_module.conf
  etc/modprobe.d/omarchy-usb-autosuspend.conf
  etc/nsswitch.conf
  etc/plymouth/plymouthd.conf
  etc/security/faillock.conf
  etc/sysctl.d/99-omarchy-sysctl.conf
  etc/systemd/oomd.conf.d/10-omarchy.conf
  etc/systemd/zram-generator.conf
  etc/tmpfiles.d/omarchy-zswap.conf
  icon.png
  icon.txt
  install/fixture
  logo.svg
  logo.txt
  migrations/1000.sh
  shell/fixture.qml
  themes/fixture
  version
)

make_source() {
  local tree=$1 profile=$2 path
  for path in "${files[@]}"; do
    mkdir -p "$(dirname "$tree/$path")"
    printf 'fixture: %s\n' "$path" >"$tree/$path"
  done
  cp "$root/tests/fixtures/settings-boot/omarchy_hooks-v4.0.4.conf" \
    "$tree/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
  printf 'r! /etc/sudoers.d/99-omarchy-nopasswd-*\n' >"$tree/etc/tmpfiles.d/omarchy-nopasswd-sudo.conf"
  if [[ $profile == legacy ]]; then
    printf '#!/bin/bash\nprintf "legacy helper survives\\n"\n' >"$tree/bin/omarchy-sudo-passwordless"
  else
    cat >"$tree/bin/omarchy-sudo-passwordless" <<'HELPER'
#!/bin/bash
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/omarchy-security-functions"
[[ ${1:-} == __package-removing ]] || exit 1
security_payload_probe
HELPER
    cat >"$tree/bin/omarchy-security-functions" <<'LIBRARY'
security_payload_probe() { printf 'modern helper and sibling library survive\n'; }
LIBRARY
    cat >"$tree/default/libalpm/hooks/05-omarchy-passwordless-revoke.hook" <<'HOOK'
[Trigger]
Operation = Upgrade
Operation = Remove
Type = Package
Target = omarchy-settings
Target = omarchy-settings-dev

[Action]
Description = Revoking temporary Omarchy sudo grants before settings changes...
When = PreTransaction
Exec = /usr/bin/omarchy-sudo-passwordless __package-removing
AbortOnFail
HOOK
  fi
}

package_as() (
  local recipe=$1 tree=$2 architecture=$3 output=$4
  export CARCH=$architecture OMARCHY_SRC=$tree srcdir=$output-source pkgdir=$output
  mkdir -p "$srcdir" "$pkgdir"
  ln -s "$tree" "$srcdir/omarchy"
  # A separate Bash preserves errexit inside package(), even when the caller
  # is checking an expected failure using an if statement.
  bash -euo pipefail -c '
    source "$1"
    package
    printf "%s\n" "${depends[@]}" >"$2.depends"
    printf "pkgname = %s\npkgver = %s-%s\narch = %s\n" "$pkgname" "$pkgver" "$pkgrel" "$CARCH" >"$2.metadata"
  ' bash "$root/pkgbuilds/$recipe/PKGBUILD" "$output"
)

assert_settings_file() {
  local tree=$1 package_root=$2 relative=$3 source_relative=$4 mode=$5
  [[ -f $package_root/$relative && ! -L $package_root/$relative ]] || fail "settings is missing $relative"
  cmp "$tree/$source_relative" "$package_root/$relative" || fail "wrong payload at $relative"
  [[ $(stat -c '%a' "$package_root/$relative") == "$mode" ]] || fail "wrong mode at $relative"
}

for profile in legacy modern; do
  make_source "$scratch/$profile" "$profile"
done

for flavour in stable dev; do
  runtime=omarchy settings=omarchy-settings
  if [[ $flavour == dev ]]; then runtime+=-dev; settings+=-dev; fi
  for architecture in x86_64 aarch64; do
    for profile in legacy modern; do
      case_name=$flavour-$architecture-$profile
      tree=$scratch/$profile
      runtime_root=$scratch/$case_name-runtime
      settings_root=$scratch/$case_name-settings
      merged=$scratch/$case_name-installed
      package_as "$runtime" "$tree" "$architecture" "$runtime_root"
      package_as "$settings" "$tree" "$architecture" "$settings_root"
      for dependency in bash coreutils gawk sudo systemd util-linux; do
        grep -Fxq "$dependency" "$settings_root.depends" || fail "$case_name: settings lacks $dependency runtime dependency"
      done

      helpers=(omarchy-sudo-passwordless)
      [[ $profile != modern ]] || helpers+=(omarchy-security-functions)
      for helper in "${helpers[@]}"; do
        assert_settings_file "$tree" "$settings_root" "usr/bin/$helper" "bin/$helper" 755
        link=usr/share/omarchy/bin/$helper
        [[ -L $settings_root/$link && $(readlink "$settings_root/$link") == "/usr/bin/$helper" ]] || fail "$case_name: missing canonical $link"
        [[ ! -e $runtime_root/usr/bin/$helper && ! -L $runtime_root/$link ]] || fail "$case_name: runtime still owns $helper"
      done
      assert_settings_file "$tree" "$settings_root" etc/tmpfiles.d/omarchy-nopasswd-sudo.conf etc/tmpfiles.d/omarchy-nopasswd-sudo.conf 644
      hook=usr/share/libalpm/hooks/05-omarchy-passwordless-revoke.hook
      if [[ $profile == modern ]]; then
        assert_settings_file "$tree" "$settings_root" "$hook" default/libalpm/hooks/05-omarchy-passwordless-revoke.hook 644
      else
        [[ ! -e $settings_root/$hook && ! -e $settings_root/usr/bin/omarchy-security-functions && ! -L $settings_root/usr/share/omarchy/bin/omarchy-security-functions ]] || fail "$case_name: invented modern files for legacy source"
      fi

      # Check all file and symlink ownership, then model removing exactly the
      # runtime's file list. Never follow package symlinks into the host root.
      python3 - "$runtime_root" "$settings_root" "$merged" <<'PY'
from pathlib import Path
import shutil
import sys

runtime, settings, merged = map(Path, sys.argv[1:])
def payload(tree):
    return {path.relative_to(tree) for path in tree.rglob("*") if path.is_symlink() or path.is_file()}
runtime_files, settings_files = payload(runtime), payload(settings)
collision = runtime_files & settings_files
assert not collision, "runtime/settings payload collision: " + ", ".join(map(str, sorted(collision)))
shutil.copytree(settings, merged, symlinks=True)
shutil.copytree(runtime, merged, symlinks=True, dirs_exist_ok=True)
for relative in runtime_files:
    (merged / relative).unlink()
assert not (merged / "usr/bin/omarchy-runtime-probe").exists(), "runtime removal was not exercised"
for relative in settings_files:
    path = merged / relative
    assert path.is_symlink() or path.is_file(), "runtime removal lost settings payload: " + str(relative)
PY
      # Probe execution through the installed helper and its sibling library;
      # byte comparisons above separately verify both are the source payload.
      actual=$(bash "$merged/usr/bin/omarchy-sudo-passwordless" __package-removing)
      if [[ $profile == legacy ]]; then
        [[ $actual == 'legacy helper survives' ]] || fail "$case_name: legacy helper lost"
      else
        [[ $actual == 'modern helper and sibling library survive' ]] || fail "$case_name: helper dependency lost"
      fi
      if [[ -n $payload_capture ]]; then
        # Optional offline ALPM tests consume these actual package() outputs.
        # mkdir deliberately refuses to overwrite an earlier captured case.
        capture=$payload_capture/$case_name
        mkdir "$capture"
        cp -a "$runtime_root" "$capture/runtime"
        cp -a "$settings_root" "$capture/settings"
        cp "$runtime_root.depends" "$capture/runtime.depends"
        cp "$settings_root.depends" "$capture/settings.depends"
        cp "$runtime_root.metadata" "$capture/runtime.metadata"
        cp "$settings_root.metadata" "$capture/settings.metadata"
      fi
      printf 'ok - %s: exclusive settings ownership survives runtime removal\n' "$case_name"
    done
  done
done

# A hook without its command, sourced library or reboot cleanup would leave a
# package transaction calling missing support. Reject such partial sources at
# build time, including the stable recipe's optional newer-source path.
for settings in omarchy-settings omarchy-settings-dev; do
  for missing in bin/omarchy-sudo-passwordless bin/omarchy-security-functions etc/tmpfiles.d/omarchy-nopasswd-sudo.conf; do
    case_name=$settings-missing-${missing##*/}
    tree=$scratch/$case_name
    cp -a "$scratch/modern" "$tree"
    rm "$tree/$missing"
    if package_as "$settings" "$tree" x86_64 "$scratch/$case_name-payload" >"$scratch/$case_name.log" 2>&1; then
      fail "$case_name: accepted an incomplete revocation payload"
    fi
    grep -q 'Passwordless-sudo revocation requires' "$scratch/$case_name.log" || fail "$case_name: failed for an unrelated reason"
    printf 'ok - %s: incomplete hook support is rejected\n' "$case_name"
  done
done
