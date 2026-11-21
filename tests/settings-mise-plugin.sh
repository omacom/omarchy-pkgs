#!/bin/bash
# Build both settings recipes from a synthetic source tree: Omarchy's mise
# settings plugin ships where mise looks for system plugins, with modes mise
# accepts whatever the build host's were, and a source without the plugin
# ships nothing there.
set -euo pipefail

BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fixture=$scratch/src/omarchy

plugin_files=(
  metadata.lua
  mise.plugin.toml
  hooks/settings_read.lua
  hooks/settings_write.lua
  lib/settings.lua
)

mapfile -t files < "$BUILD_ROOT/tests/fixtures/settings-source-files"
for path in "${plugin_files[@]}"; do
  files+=("default/mise/plugins/omarchy/$path")
done
for path in "${files[@]}"; do
  mkdir -p "$(dirname "$fixture/$path")"
  printf 'fixture for %s\n' "$path" > "$fixture/$path"
done
# The aarch64 recipe parses the HOOKS line.
cp "$BUILD_ROOT/tests/fixtures/settings-boot/omarchy_hooks-v4.0.4.conf" "$fixture/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
# A build host with umask 002 checks the source out group-writable.
chmod -R g+w "$fixture/default/mise"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

build_recipe() { # build_recipe <recipe> <arch> <source> <output name>
  (
    export CARCH=$2 OMARCHY_SRC=$3
    export srcdir=${3%/omarchy} pkgdir=$scratch/$4
    backup=()
    # shellcheck disable=SC1090 # Exercise each recipe's actual package function.
    source "$BUILD_ROOT/pkgbuilds/$1/PKGBUILD"
    package
  ) >/dev/null
}

legacy=$scratch/legacy/omarchy
mkdir -p "$(dirname "$legacy")"
cp -a "$fixture" "$legacy"
rm -r "$legacy/default/mise"

for recipe in omarchy-settings-dev omarchy-settings; do
  for target_arch in x86_64 aarch64; do
    build_recipe "$recipe" "$target_arch" "$fixture" "$recipe-$target_arch"
    plugin=$scratch/$recipe-$target_arch/usr/share/mise/plugins/omarchy

    for path in "${plugin_files[@]}"; do
      cmp -s "$fixture/default/mise/plugins/omarchy/$path" "$plugin/$path" ||
        fail "$target_arch: $recipe does not ship /usr/share/mise/plugins/omarchy/$path"
    done
    shipped=$(cd "$plugin" && find . -type f | sort)
    expected=$(printf './%s\n' "${plugin_files[@]}" | sort)
    [[ $shipped == "$expected" ]] ||
      fail "$target_arch: $recipe ships other files in the plugin:"$'\n'"$shipped"
    writable=$(find "$plugin" -perm /022)
    [[ -z $writable ]] ||
      fail "$target_arch: $recipe ships plugin paths group or other can write, which mise refuses:"$'\n'"$writable"
    [[ -z $(find "$plugin" -type d ! -perm 755) && -z $(find "$plugin" -type f ! -perm 644) ]] ||
      fail "$target_arch: $recipe ships plugin paths that are not 755 directories and 644 files"
    echo "PASS: $target_arch: $recipe ships the mise settings plugin where mise finds it"

    build_recipe "$recipe" "$target_arch" "$legacy" "legacy-$recipe-$target_arch"
    [[ ! -e $scratch/legacy-$recipe-$target_arch/usr/share/mise ]] ||
      fail "$target_arch: $recipe ships /usr/share/mise from a source without the plugin"
    echo "PASS: $target_arch: $recipe ships no mise plugin from a source without one"
  done
done
