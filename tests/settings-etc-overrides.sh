#!/bin/bash
# Run each settings package's real _etc_overrides_apply against a scratch root,
# on Apple Silicon and elsewhere, with cups-browsed installed and not: every
# override lands on both platforms, and only /etc/os-release differs, staying
# Arch Linux ARM's symlink on Apple Silicon (omarchy-pkgs#1857).
set -euo pipefail

BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

overrides=(os-release security-faillock.conf nsswitch.conf cups-cups-browsed.conf
  plymouth-plymouthd.conf dot.bashrc)

# Override and the path it lands on, for those both platforms apply.
declare -A target=(
  [security-faillock.conf]=etc/security/faillock.conf
  [nsswitch.conf]=etc/nsswitch.conf
  [plymouth-plymouthd.conf]=etc/plymouth/plymouthd.conf
  [dot.bashrc]=etc/skel/.bashrc
)

for recipe in omarchy-settings omarchy-settings-dev; do
  install_script=$BUILD_ROOT/pkgbuilds/$recipe/$recipe.install
  for platform in apple other; do
    for browsed in present absent; do
      case_name="$recipe, $platform, cups-browsed $browsed"
      root=$scratch/$recipe-$platform-$browsed
      mkdir -p "$root/ov" "$root/etc" "$root/usr/lib"
      for name in "${overrides[@]}"; do printf 'omarchy %s\n' "$name" >"$root/ov/$name"; done
      printf 'ID=archarm\n' >"$root/usr/lib/os-release"
      if [[ $browsed == present ]]; then
        mkdir -p "$root/etc/cups"
        printf 'stock cups-browsed\n' >"$root/etc/cups/cups-browsed.conf"
      fi

      # Point every absolute path at the scratch root. The relative symlink
      # target ../usr/lib/os-release stays as it is.
      sed -n '/^_etc_overrides_apply() {/,/^}/p' "$install_script" |
        sed -e "s#/usr/share/omarchy/etc-overrides#$root/ov#g" \
          -e "s#\([ (]\)/etc/#\1$root/etc/#g" \
          -e "s#\([ (]\)/usr/lib/#\1$root/usr/lib/#g" >"$root/apply.sh"
      grep -q '^_etc_overrides_apply() {' "$root/apply.sh" || fail "$case_name: no _etc_overrides_apply"
      # Refuse to run anything that could still reach the real system.
      if grep -E '(^|[ ("])/(etc|usr)/' "$root/apply.sh"; then
        fail "$case_name: a path escaped the scratch root"
      fi

      (
        # shellcheck disable=SC1091 # Generated above from the real install script.
        source "$root/apply.sh"
        if [[ $platform == apple ]]; then _apple_silicon() { true; }; else _apple_silicon() { false; }; fi
        _etc_overrides_apply >/dev/null
      )

      if [[ $platform == apple ]]; then
        [[ -L $root/etc/os-release && $(readlink "$root/etc/os-release") == "../usr/lib/os-release" ]] ||
          fail "$case_name: /etc/os-release is not Arch Linux ARM's symlink"
      else
        [[ ! -L $root/etc/os-release ]] && cmp -s "$root/ov/os-release" "$root/etc/os-release" &&
          [[ $(stat -c %a "$root/etc/os-release") == 644 ]] ||
          fail "$case_name: /etc/os-release is not Omarchy's, mode 644"
      fi
      for name in "${!target[@]}"; do
        path=$root/${target[$name]}
        cmp -s "$root/ov/$name" "$path" && [[ $(stat -c %a "$path") == 644 ]] ||
          fail "$case_name: /${target[$name]} is not Omarchy's, mode 644"
      done
      if [[ $browsed == present ]]; then
        cmp -s "$root/ov/cups-cups-browsed.conf" "$root/etc/cups/cups-browsed.conf" &&
          [[ $(stat -c %a "$root/etc/cups/cups-browsed.conf") == 644 ]] ||
          fail "$case_name: /etc/cups/cups-browsed.conf is not Omarchy's, mode 644"
      else
        [[ ! -e $root/etc/cups/cups-browsed.conf ]] ||
          fail "$case_name: created /etc/cups/cups-browsed.conf before cups-browsed is installed"
      fi
      pass "$case_name"
    done
  done
done
