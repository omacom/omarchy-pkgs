#!/bin/bash
# Run the omarchy-settings recipes' package() against synthetic source trees:
# an older source keeps today's per-architecture package, and a source that
# selects its platform profile at runtime ships the same files, backup and
# optdepends on aarch64 as on x86_64.
set -euo pipefail
export LC_ALL=C

BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  printf 'FAIL: %s\n' "$@" >&2
  exit 1
}

files=(
  applications/example.desktop
  bin/omarchy-debug
  bin/omarchy-debug-idle
  bin/omarchy-upload-log
  config/autostart/limine-snapper-notify.desktop
  config/hypr/hyprland.lua
  default/applications/mimeapps.list
  default/bashrc
  default/environment.d/10-omarchy-fcitx.conf
  default/fontconfig/conf.avail/50-omarchy.conf
  default/fonts/omarchy/omarchy.ttf
  default/hypr/toggles/flags.lua
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
  logo.svg
  logo.txt
)
# Left out of an older source's aarch64 package, and nothing else is.
legacy_aarch64_absent=(
  etc/limine-entry-tool.d/omarchy-defaults.conf
  etc/limine-entry-tool.d/omarchy-uki.conf
  etc/mkinitcpio.conf.d/omarchy_hooks.conf
  etc/mkinitcpio.conf.d/thunderbolt_module.conf
  etc/modprobe.d/omarchy-usb-autosuspend.conf
  etc/skel/.config/autostart/limine-snapper-notify.desktop
  etc/systemd/oomd.conf.d/10-omarchy.conf
  etc/systemd/zram-generator.conf
  etc/tmpfiles.d/omarchy-zswap.conf
  usr/lib/systemd/user/app.slice.d/10-oomd.conf
  usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf
  usr/share/omarchy/config/autostart/limine-snapper-notify.desktop
  usr/share/omarchy/default/limine/default.conf
  usr/share/omarchy/default/limine/limine.conf
)
x86_backup=(
  etc/limine-entry-tool.d/omarchy-defaults.conf
  etc/limine-entry-tool.d/omarchy-uki.conf
  etc/mkinitcpio.conf.d/omarchy_hooks.conf
  etc/mkinitcpio.conf.d/thunderbolt_module.conf
  etc/modprobe.d/omarchy-usb-autosuspend.conf
  etc/systemd/oomd.conf.d/10-omarchy.conf
  etc/systemd/zram-generator.conf
)
keyboard_unit=default/systemd/user/omarchy-brightness-keyboard-auto.service

# $1: source tree. Extra arguments are files to add to it.
make_source() {
  local tree=$1 path
  shift
  for path in "${files[@]}" "$@"; do
    mkdir -p "$(dirname "$tree/$path")"
    printf 'fixture for %s\n' "$path" >"$tree/$path"
  done
}

# Runs package() as makepkg would for one architecture (arch-specific arrays
# merged first) and records the package tree and its metadata. $1: recipe,
# $2: source tree, $3: CARCH, $4: output name, $5: "checkout" to build through
# OMARCHY_SRC, "pinned" for the git source.
package_as() {
  local recipe=$1 tree=$2 carch=$3 name=$4 mode=$5
  (
    unset OMARCHY_SRC
    [[ $mode == "pinned" ]] || export OMARCHY_SRC=$tree
    export CARCH=$carch srcdir=$scratch/$name-src pkgdir=$scratch/$name
    mkdir -p "$srcdir" "$pkgdir"
    ln -sfn "$tree" "$srcdir/omarchy"
    backup=()
    # shellcheck disable=SC1090 # Exercise the recipe's own package function.
    source "$BUILD_ROOT/pkgbuilds/$recipe/PKGBUILD"
    eval "optdepends+=(\"\${optdepends_${carch}[@]}\")"
    package
    printf '%s\n' "${backup[@]}" | sort >"$scratch/$name.backup"
    # shellcheck disable=SC2154 # Set by the recipe.
    printf '%s\n' "${optdepends[@]}" >"$scratch/$name.optdepends"
    (cd "$pkgdir" && find . \( -type f -o -type l \) | sed 's|^\./||' | sort) >"$scratch/$name.files"
  )
}

in_list() {
  grep -Fxq -- "$1" "$2"
}

make_source "$scratch/legacy"
make_source "$scratch/profile" default/settings-runtime-profile "$keyboard_unit"

for recipe in omarchy-settings omarchy-settings-dev; do
  rm -rf "${scratch:?}"/legacy-* "${scratch:?}"/profile-*
  # An older source keeps the per-architecture package it has always had.
  package_as "$recipe" "$scratch/legacy" x86_64 legacy-x86_64 pinned
  package_as "$recipe" "$scratch/legacy" aarch64 legacy-aarch64 pinned
  for path in "${legacy_aarch64_absent[@]}"; do
    in_list "$path" "$scratch/legacy-x86_64.files" || fail "older source ships $path on x86_64"
    ! in_list "$path" "$scratch/legacy-aarch64.files" || fail "older source leaves $path out on aarch64"
  done
  missing=$(comm -23 "$scratch/legacy-x86_64.files" "$scratch/legacy-aarch64.files")
  [[ $missing == "$(printf '%s\n' "${legacy_aarch64_absent[@]}" | sort)" ]] ||
    fail "older source's aarch64 package differs from x86_64 only by the boot and memory drop-ins" "$missing"
  cmp -s "$scratch/legacy/etc/sysctl.d/99-omarchy-sysctl.conf" "$scratch/legacy-x86_64/etc/sysctl.d/99-omarchy-sysctl.conf" ||
    fail 'x86_64 ships the source sysctl file'
  ! cmp -s "$scratch/legacy/etc/sysctl.d/99-omarchy-sysctl.conf" "$scratch/legacy-aarch64/etc/sysctl.d/99-omarchy-sysctl.conf" ||
    fail 'older source keeps only the network tuning on aarch64'
  for path in "${x86_backup[@]}"; do
    in_list "$path" "$scratch/legacy-x86_64.backup" || fail "x86_64 backs up $path"
    ! in_list "$path" "$scratch/legacy-aarch64.backup" || fail "older source's aarch64 backup leaves out $path"
  done
  grep -q '^limine:' "$scratch/legacy-x86_64.optdepends" || fail 'x86_64 suggests the boot stack its drop-ins are for'
  ! grep -q '^limine:' "$scratch/legacy-aarch64.optdepends" || fail "older source's aarch64 package suggests no boot stack"
  ! in_list usr/lib/systemd/user/omarchy-brightness-keyboard-auto.service "$scratch/legacy-x86_64.files" ||
    fail 'a source without the keyboard unit ships none'
  echo "PASS: $recipe: an older source keeps its per-architecture package"

  # A runtime-profile source ships the same tree and metadata on both.
  package_as "$recipe" "$scratch/profile" x86_64 profile-x86_64 checkout
  package_as "$recipe" "$scratch/profile" aarch64 profile-aarch64 pinned
  cmp -s "$scratch/profile-x86_64.files" "$scratch/profile-aarch64.files" ||
    fail 'runtime-profile source ships the same files on both architectures' \
      "$(diff "$scratch/profile-x86_64.files" "$scratch/profile-aarch64.files")"
  while IFS= read -r path; do
    if [[ -L $scratch/profile-x86_64/$path ]]; then
      [[ $(readlink "$scratch/profile-x86_64/$path") == "$(readlink "$scratch/profile-aarch64/$path")" ]]
    else
      cmp -s "$scratch/profile-x86_64/$path" "$scratch/profile-aarch64/$path"
    fi || fail "runtime-profile source ships the same $path on both architectures"
  done <"$scratch/profile-x86_64.files"
  cmp -s "$scratch/profile-x86_64.backup" "$scratch/profile-aarch64.backup" ||
    fail 'runtime-profile source backs up the same files on both architectures'
  cmp -s "$scratch/profile-x86_64.optdepends" "$scratch/profile-aarch64.optdepends" ||
    fail 'runtime-profile source has the same optdepends on both architectures'
  in_list usr/lib/systemd/user/omarchy-brightness-keyboard-auto.service "$scratch/profile-aarch64.files" ||
    fail 'the keyboard unit first-run enables ships when the source has it'
  comm -13 "$scratch/legacy-x86_64.files" "$scratch/profile-x86_64.files" >"$scratch/added"
  [[ $(cat "$scratch/added") == "$(printf '%s\n' usr/lib/systemd/user/omarchy-brightness-keyboard-auto.service usr/share/omarchy/default/settings-runtime-profile "usr/share/omarchy/$keyboard_unit" | sort)" ]] ||
    fail 'x86_64 gains only the keyboard unit and the marker from a runtime-profile source' "$(cat "$scratch/added")"
  echo "PASS: $recipe: a runtime-profile source ships the full set on aarch64"
done
