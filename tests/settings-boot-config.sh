#!/bin/bash
# Exercise the real package functions with a minimal, synthetic runtime tree.
set -euo pipefail

BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fixture=$scratch/src/omarchy

files=(
  config/autostart/limine-snapper-notify.desktop
  etc/fastfetch/config.jsonc
  etc/mkinitcpio.conf.d/omarchy_hooks.conf
  etc/mkinitcpio.conf.d/thunderbolt_module.conf
  etc/limine-entry-tool.d/omarchy-defaults.conf
  etc/limine-entry-tool.d/omarchy-uki.conf
  etc/security/faillock.conf
  etc/nsswitch.conf
  etc/cups/cups-browsed.conf
  etc/cups/cups-files.conf
  etc/plymouth/plymouthd.conf
  etc/sysctl.d/99-omarchy-sysctl.conf
  default/uwsm/env.d/10-omarchy
  default/environment.d/10-omarchy-fcitx.conf
  default/fontconfig/conf.avail/50-omarchy.conf
  default/xdg-terminal-exec/hyprland-xdg-terminals.list
  default/applications/mimeapps.list
  default/systemd/user/bt-agent.service
  default/systemd/user/omarchy-sleep-lock.service
  default/systemd/user/omarchy-recover-internal-monitor.service
  default/systemd/user/omarchy-migrate-notify.service
  default/systemd/user/omarchy-tailscale-receive.service
  default/systemd/user/omarchy-fcitx5.service
  default/systemd/user/omarchy-crash-watch.service
  default/systemd/user/app.slice.d/10-oomd.conf
  default/systemd/zram-generator.conf.d/90-omarchy.conf
  default/systemd/system/plocate-updatedb.service.d/10-omarchy.conf
  default/systemd/system-sleep/unmount-fuse
  default/bashrc
  default/limine/default.conf
  default/limine/limine.conf
  default/snapper/root
  default/sddm/omarchy/Main.qml
  default/sddm/hyprland.lua
  default/wayland-sessions/omarchy.desktop
  default/plymouth/omarchy.plymouth
  default/fonts/omarchy/omarchy.ttf
  default/hypr/toggles/flags.lua
  default/nautilus-python/extensions/localsend.py
  default/nautilus-python/extensions/transcode.py
  default/tensaku/state.toml
  applications/example.desktop
  bin/omarchy-upload-log
  bin/omarchy-debug
  bin/omarchy-debug-idle
  logo.txt
  logo.svg
  icon.txt
  icon.png
)
for path in "${files[@]}"; do
  mkdir -p "$(dirname "$fixture/$path")"
  printf 'fixture for %s\n' "$path" > "$fixture/$path"
done

for recipe in omarchy-settings omarchy-settings-dev; do
  for target_arch in aarch64 x86_64; do
    (
      export CARCH=$target_arch OMARCHY_SRC=$fixture
      export srcdir=$scratch/src pkgdir=$scratch/$recipe-$target_arch
      backup=()
      # shellcheck disable=SC1090 # Exercise each recipe's actual package function.
      source "$BUILD_ROOT/pkgbuilds/$recipe/PKGBUILD"
      package

      for path in etc/mkinitcpio.conf.d/omarchy_hooks.conf \
        etc/limine-entry-tool.d/omarchy-defaults.conf \
        etc/limine-entry-tool.d/omarchy-uki.conf; do
        cmp "$fixture/$path" "$pkgdir/$path"
        printf '%s\n' "${backup[@]}" | grep -Fxq "$path"
      done
      for template in default.conf limine.conf; do
        cmp "$fixture/default/limine/$template" "$pkgdir/usr/share/omarchy/default/limine/$template"
      done
      # The installer owns the machine-specific live configuration.
      [[ ! -e $pkgdir/etc/default/limine ]]
      if printf '%s\n' "${backup[@]}" | grep -Fxq 'etc/default/limine'; then
        echo 'FAIL: installer-owned Limine configuration is in backup metadata' >&2
        exit 1
      fi
      cmp "$fixture/config/autostart/limine-snapper-notify.desktop" \
        "$pkgdir/etc/skel/.config/autostart/limine-snapper-notify.desktop"
      cmp "$fixture/config/autostart/limine-snapper-notify.desktop" \
        "$pkgdir/usr/share/omarchy/config/autostart/limine-snapper-notify.desktop"

      thunderbolt=etc/mkinitcpio.conf.d/thunderbolt_module.conf
      if [[ $CARCH == aarch64 ]]; then
        [[ ! -e $pkgdir/$thunderbolt ]]
        if printf '%s\n' "${backup[@]}" | grep -Fxq "$thunderbolt"; then
          echo 'FAIL: removed ARM Thunderbolt config remains in backup metadata' >&2
          exit 1
        fi
      else
        cmp "$fixture/$thunderbolt" "$pkgdir/$thunderbolt"
        printf '%s\n' "${backup[@]}" | grep -Fxq "$thunderbolt"
      fi
      echo "PASS: $recipe $CARCH retains boot configuration and matching backup metadata"
    )
  done
done
