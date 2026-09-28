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

fixtures=$BUILD_ROOT/tests/fixtures/settings-boot
# Omarchy's HOOKS line, as v4.0.4 ships it (omarchy_hooks-v4.0.4.conf).
omarchy_hooks='base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs'
cp "$fixtures/omarchy_hooks-v4.0.4.conf" "$fixture/etc/mkinitcpio.conf.d/omarchy_hooks.conf"

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
        printf '%s\n' "${backup[@]}" | grep -Fxq "$path"
      done
      for path in etc/limine-entry-tool.d/omarchy-defaults.conf etc/limine-entry-tool.d/omarchy-uki.conf; do
        cmp "$fixture/$path" "$pkgdir/$path"
      done
      hooks_conf=etc/mkinitcpio.conf.d/omarchy_hooks.conf
      if [[ $CARCH == aarch64 ]]; then
        grep -Fxq 'if [[ " ${HOOKS[*]:-} " != *" asahi "* ]]; then' "$pkgdir/$hooks_conf"
        bash -n "$pkgdir/$hooks_conf"
      else
        cmp "$fixture/$hooks_conf" "$pkgdir/$hooks_conf"
      fi
      for template in default.conf limine.conf; do
        cmp "$fixture/default/limine/$template" "$pkgdir/usr/share/omarchy/default/limine/$template"
      done
      if printf '%s\n' "${backup[@]}" | grep -Fxq etc/mkinitcpio.conf.d/00-omarchy-hooks.conf; then
        echo 'FAIL: backup names a 00-omarchy-hooks.conf the source does not ship' >&2
        exit 1
      fi
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

# The aarch64 packages also reach Apple Silicon Macs, whose initramfs needs the
# asahi hook. Source mkinitcpio.conf and the drop-ins in mkinitcpio's order and
# compare the resulting HOOKS for each kind of aarch64 install. Aurora Macs use
# omarchy-mac-boot's real 90-94 fragments (omacom/omarchy-mac ff7ce0d4d).
package_aarch64() {
  local recipe=$1 source_tree=$2 out=$3
  (
    # package() builds from $srcdir/omarchy.
    export CARCH=aarch64 OMARCHY_SRC=$source_tree srcdir=${source_tree%/omarchy} pkgdir=$out
    backup=()
    # shellcheck disable=SC1090 # Exercise the recipe's actual package function.
    source "$BUILD_ROOT/pkgbuilds/$recipe/PKGBUILD"
    package || exit 1
    printf '%s\n' "${backup[@]}" > "$out.backup"
  )
}

# omacom/omarchy#13362 asks omarchy-hw-platform which machine it is on.
for platform in apple-silicon qualcomm generic-aarch64; do
  mkdir -p "$scratch/detector-$platform"
  printf '#!/bin/sh\necho %s\n' "$platform" > "$scratch/detector-$platform/omarchy-hw-platform"
  chmod +x "$scratch/detector-$platform/omarchy-hw-platform"
done

# effective_hooks ROOT [PLATFORM]
effective_hooks() {
  local root=$1 platform=${2:-}
  (
    LC_ALL=C
    [[ -z $platform ]] || PATH=$scratch/detector-$platform:$PATH
    HOOKS=() MODULES=() FILES=()
    # shellcheck disable=SC1091
    source "$root/mkinitcpio.conf"
    shopt -s nullglob
    for conf in "$root"/mkinitcpio.conf.d/*.conf; do
      # shellcheck disable=SC1090
      source "$conf"
    done
    echo "${HOOKS[*]}"
  )
}

# machine NAME MKINITCPIO_HOOKS PACKAGED_ETC [mac-boot]
machine() {
  local root=$scratch/machines/$1
  rm -rf "$root"
  mkdir -p "$root/mkinitcpio.conf.d"
  printf 'HOOKS=(%s)\n' "$2" > "$root/mkinitcpio.conf"
  [[ -z $3 ]] || cp "$3"/*.conf "$root/mkinitcpio.conf.d/"
  [[ ${4:-} != mac-boot ]] || cp "$fixtures"/omarchy-mac-boot/*.conf "$root/mkinitcpio.conf.d/"
  printf '%s\n' "$root"
}

expect() {
  local layout=$1 what=$2 got=$3 want=$4
  [[ $got == "$want" ]] || { echo "FAIL: $layout: $what gets '$got', want '$want'" >&2; exit 1; }
}

arch_default='base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck'
snapdragon='base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck'
legacy_mac='base udev autodetect modconf kms keyboard keymap consolefont block asahi encrypt filesystems fsck'

# Macs must come out exactly as they would without omarchy-settings' drop-ins.
check_macs() {
  local layout=$1 packaged=$2 base
  for base in "$arch_default" "$snapdragon"; do
    expect "$layout" "an Aurora Mac" \
      "$(effective_hooks "$(machine aurora "$base" "$packaged" mac-boot)")" \
      "$(effective_hooks "$(machine aurora-bare "$base" "" mac-boot)")"
  done
  expect "$layout" "a legacy GRUB Mac" \
    "$(effective_hooks "$(machine legacy "$legacy_mac" "$packaged")")" "$legacy_mac"
  expect "$layout" "a legacy GRUB Mac with the Apple fragments" \
    "$(effective_hooks "$(machine legacy-boot "$legacy_mac" "$packaged" mac-boot)")" \
    "$(effective_hooks "$(machine legacy-boot-bare "$legacy_mac" "" mac-boot)")"
}

layout="HOOKS in omarchy_hooks.conf (v4.0.4)"
packaged=$scratch/omarchy-settings-aarch64/etc/mkinitcpio.conf.d
expect "$layout" Snapdragon "$(effective_hooks "$(machine snapdragon "$snapdragon" "$packaged")")" "$omarchy_hooks"
expect "$layout" "the DGX Spark" "$(effective_hooks "$(machine spark "$arch_default" "$packaged")")" "$omarchy_hooks"
check_macs "$layout" "$packaged"
echo "PASS: $layout: Snapdragon and the Spark get Omarchy's hooks; Macs keep theirs"

# omacom/omarchy#13362 decides per platform in 00-omarchy-hooks.conf; the
# package ships both of its files unchanged.
split=$scratch/split/omarchy
mkdir -p "$scratch/split"
cp -a "$fixture" "$split"
cp "$fixtures"/omarchy-13362/*.conf "$split/etc/mkinitcpio.conf.d/"
# Its 00-omarchy-hooks.conf asks the detector copy the platform guard ships.
for path in default/libalpm/hooks/00-omarchy-platform-guard.hook \
  default/libalpm/scripts/omarchy-platform-guard bin/omarchy-hw-platform; do
  mkdir -p "$(dirname "$split/$path")"
  printf 'fixture for %s\n' "$path" > "$split/$path"
done
for recipe in omarchy-settings omarchy-settings-dev; do
  package_aarch64 "$recipe" "$split" "$scratch/split-$recipe" >/dev/null
  for conf in 00-omarchy-hooks.conf omarchy_hooks.conf; do
    cmp "$fixtures/omarchy-13362/$conf" "$scratch/split-$recipe/etc/mkinitcpio.conf.d/$conf"
  done
  grep -Fxq etc/mkinitcpio.conf.d/00-omarchy-hooks.conf "$scratch/split-$recipe.backup"
  [[ -x $scratch/split-$recipe/usr/share/libalpm/scripts/omarchy-hw-platform ]]
done
layout="omacom/omarchy#13362 (00-omarchy-hooks.conf)"
packaged=$scratch/split-omarchy-settings/etc/mkinitcpio.conf.d
for platform in "" qualcomm generic-aarch64; do
  expect "$layout" "Snapdragon (${platform:-no detector})" \
    "$(effective_hooks "$(machine snapdragon "$snapdragon" "$packaged")" "$platform")" "$omarchy_hooks"
  expect "$layout" "the DGX Spark (${platform:-no detector})" \
    "$(effective_hooks "$(machine spark "$arch_default" "$packaged")" "$platform")" "$omarchy_hooks"
done
expect "$layout" "a legacy GRUB Mac" \
  "$(effective_hooks "$(machine legacy "$legacy_mac" "$packaged")" apple-silicon)" "$legacy_mac"
# An Aurora Mac builds on the systemd baseline and unlocks with sd-encrypt.
hooks=" $(effective_hooks "$(machine aurora "$arch_default" "$packaged" mac-boot)" apple-silicon) "
for hook in systemd asahi omarchy-vendorfw omarchy-mac-encrypt sd-encrypt; do
  [[ $hooks == *" $hook "* ]] || { echo "FAIL: $layout: an Aurora Mac lacks $hook:$hooks" >&2; exit 1; }
done
for hook in udev encrypt; do
  [[ $hooks != *" $hook "* ]] || { echo "FAIL: $layout: an Aurora Mac keeps $hook:$hooks" >&2; exit 1; }
done
echo "PASS: $layout: shipped unchanged and backed up; Snapdragon and the Spark get Omarchy's hooks; Macs keep theirs"

# Sources the recipe cannot make safe for Macs stop the aarch64 build, each
# with its own reason.
refuse() {
  local what=$1 reason=$2 conf=$3 body=$4 bad=$scratch/bad/omarchy
  rm -rf "$scratch/bad" "$scratch/bad-package"
  mkdir -p "$scratch/bad"
  cp -a "$fixture" "$bad"
  rm -f "$bad"/etc/mkinitcpio.conf.d/{00-omarchy-hooks,omarchy_hooks}.conf
  [[ -z $conf ]] || printf '%s\n' "$body" > "$bad/etc/mkinitcpio.conf.d/$conf"
  if package_aarch64 omarchy-settings "$bad" "$scratch/bad-package" 2>"$scratch/bad.err"; then
    echo "FAIL: the aarch64 package builds with $what" >&2
    exit 1
  fi
  grep -Fq "$reason" "$scratch/bad.err" ||
    { echo "FAIL: $what stops the build for another reason: $(cat "$scratch/bad.err")" >&2; exit 1; }
  echo "PASS: the aarch64 package refuses $what"
}
unsafe="must keep a Mac's asahi line"
unguardable="cannot guard this HOOKS= line"
refuse "no hooks file" "$unsafe" "" ""
refuse "a hooks file that sets no HOOKS" "$unsafe" omarchy_hooks.conf 'FILES+=(/etc/vconsole.conf)'
refuse "a HOOKS line with a trailing comment" "$unguardable" omarchy_hooks.conf "HOOKS=($omarchy_hooks) # local"
refuse "a HOOKS line split over lines" "$unguardable" omarchy_hooks.conf "HOOKS=(base udev"$'\n'"  block encrypt filesystems)"
refuse "an indented HOOKS that ignores asahi" "$unsafe" 00-omarchy-hooks.conf "if true; then"$'\n'"  HOOKS=($omarchy_hooks)"$'\n'"fi"
refuse "#13362's hooks without the platform detector" "needs the omarchy-hw-platform copy" \
  00-omarchy-hooks.conf "$(cat "$fixtures/omarchy-13362/00-omarchy-hooks.conf")"

# Upgrades: pacman replaces an unmodified hooks file, keeps a modified one and
# leaves the guarded version as .pacnew, and installs it where it was absent.
# A file restored by hand after the stripped package (as the Spark and Surface
# owners did) is adopted: it stays in place and the guarded one is .pacnew.
if ((EUID != 0)) || ! command -v pacman >/dev/null; then
  echo "SKIP: pacman upgrade checks need root"
  exit 0
fi

unguarded=$fixture/etc/mkinitcpio.conf.d/omarchy_hooks.conf
guarded=$scratch/omarchy-settings-aarch64/etc/mkinitcpio.conf.d/omarchy_hooks.conf
printf '[options]\nArchitecture = auto\nSigLevel = Never\nLocalFileSigLevel = Never\n' > "$scratch/pacman.conf"

make_pkg() {
  local ver=$1 hooks=${2:-} dir=$scratch/pkg-$1
  mkdir -p "$dir/etc/mkinitcpio.conf.d"
  [[ -z $hooks ]] || cp "$hooks" "$dir/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
  cat > "$dir/.PKGINFO" <<EOF
pkgname = omarchy-settings-upgrade-test
pkgbase = omarchy-settings-upgrade-test
pkgver = $ver
pkgdesc = omarchy-settings upgrade test
arch = any
size = 1
backup = etc/mkinitcpio.conf.d/omarchy_hooks.conf
EOF
  (cd "$dir" && bsdtar -cf "$scratch/upgrade-test-$ver-any.pkg.tar" .PKGINFO etc)
  printf '%s\n' "$scratch/upgrade-test-$ver-any.pkg.tar"
}

pacman_in() {
  local root=$1
  shift
  mkdir -p "$root/var/lib/pacman" "$root/cache"
  pacman --root "$root" --dbpath "$root/var/lib/pacman" --cachedir "$root/cache" \
    --config "$scratch/pacman.conf" --logfile /dev/null --noconfirm --nodeps --noscriptlet "$@" >/dev/null
}

stripped=$(make_pkg 1-1)
old=$(make_pkg 2-1 "$unguarded")
new=$(make_pkg 3-1 "$guarded")
installed=etc/mkinitcpio.conf.d/omarchy_hooks.conf

pacman_in "$scratch/unchanged" -U "$old"
pacman_in "$scratch/unchanged" -U "$new"
cmp "$guarded" "$scratch/unchanged/$installed"
[[ ! -e $scratch/unchanged/$installed.pacnew ]]

pacman_in "$scratch/modified" -U "$old"
echo '# local change' >> "$scratch/modified/$installed"
pacman_in "$scratch/modified" -U "$new"
grep -Fxq '# local change' "$scratch/modified/$installed"
cmp "$guarded" "$scratch/modified/$installed.pacnew"

pacman_in "$scratch/absent" -U "$stripped"
pacman_in "$scratch/absent" -U "$new"
cmp "$guarded" "$scratch/absent/$installed"

pacman_in "$scratch/restored" -U "$stripped"
mkdir -p "$scratch/restored/etc/mkinitcpio.conf.d"
cp "$unguarded" "$scratch/restored/$installed"
pacman_in "$scratch/restored" -U "$new"
cmp "$unguarded" "$scratch/restored/$installed"
cmp "$guarded" "$scratch/restored/$installed.pacnew"

# Source what the upgrades installed.
for upgrade in unchanged absent; do
  etc=$scratch/$upgrade/etc/mkinitcpio.conf.d
  expect "$upgrade upgrade" Snapdragon "$(effective_hooks "$(machine "$upgrade-snapdragon" "$snapdragon" "$etc")")" "$omarchy_hooks"
  check_macs "$upgrade upgrade" "$etc"
done
echo "PASS: pacman upgrades install the guarded hooks file and keep local changes"
