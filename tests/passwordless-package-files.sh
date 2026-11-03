#!/bin/bash
# Build both pairs from a synthetic source tree: the sudo grant command, its
# library, boot cleanup and revocation hook ship from settings, and no path
# ships from both packages, which pacman would refuse to install together.
# The stable pair also builds older pinned sources, which predate the hook and
# keep the grant command in the runtime.
set -euo pipefail

BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fixture=$scratch/src/omarchy

mapfile -t files < "$BUILD_ROOT/tests/fixtures/settings-source-files"
files+=(
  bin/omarchy-update
  default/libalpm/hooks/00-omarchy-update-guard.hook
  default/libalpm/hooks/10-omarchy-hyprland-reload-pause.hook
  default/libalpm/hooks/90-omarchy-hyprland-reload-resume.hook
  install/omarchy-base.packages
  themes/fixture/colors.toml
  migrations/1788163635.sh
  shell/shell.qml
  version
)
for path in "${files[@]}"; do
  mkdir -p "$(dirname "$fixture/$path")"
  printf 'fixture for %s\n' "$path" > "$fixture/$path"
done
# The aarch64 recipe parses the HOOKS line.
cp "$BUILD_ROOT/tests/fixtures/settings-boot/omarchy_hooks-v4.0.4.conf" "$fixture/etc/mkinitcpio.conf.d/omarchy_hooks.conf"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

hook=usr/share/libalpm/hooks/05-omarchy-passwordless-revoke.hook
boot_cleanup=etc/tmpfiles.d/omarchy-nopasswd-sudo.conf

build_recipe() { # build_recipe <recipe> <arch> <source> <output name>
  (
    export CARCH=$2 OMARCHY_SRC=$3
    export srcdir=${3%/omarchy} pkgdir=$scratch/$4
    backup=()
    # shellcheck disable=SC1090 # Exercise each recipe's actual package function.
    source "$BUILD_ROOT/pkgbuilds/$1/PKGBUILD"
    package
    printf '%s\n' "${depends[@]}" >"$scratch/$4.depends"
    printf '%s\n' "${provides[@]}" >"$scratch/$4.provides"
  ) >/dev/null
}

assert_disjoint() { # assert_disjoint <arch> <runtime output> <settings output>
  local overlap
  overlap=$(comm -12 <(cd "$scratch/$2-$1" && find . ! -type d | sort) <(cd "$scratch/$3-$1" && find . ! -type d | sort))
  [[ -z $overlap ]] || fail "$1: shipped by both $2 and $3:"$'\n'"$overlap"
}

for pair in omarchy-dev:omarchy-settings-dev omarchy:omarchy-settings; do
  runtime_recipe=${pair%%:*} settings_recipe=${pair#*:}

  # The scriptlets are what clear the hook's marker, and
  # passwordless-package-lifecycle.py only tests the file, not that it ships.
  registered=$(CARCH=x86_64 && source "$BUILD_ROOT/pkgbuilds/$settings_recipe/PKGBUILD" && echo "${install:-}")
  [[ $registered == "$settings_recipe.install" ]] ||
    fail "$settings_recipe does not register $settings_recipe.install"

  # The runtime needs the library settings provides, but only once installed:
  # the per-package builds resolve the top-level depends against what the
  # repository already publishes.
  build_depends=$(CARCH=x86_64 && source "$BUILD_ROOT/pkgbuilds/$runtime_recipe/PKGBUILD" && printf '%s\n' "${depends[@]}")
  ! grep -Fxq omarchy-security-functions <<<"$build_depends" ||
    fail "$runtime_recipe asks for omarchy-security-functions before building, which a published settings may not provide"

  for target_arch in x86_64 aarch64; do
    for recipe in "$runtime_recipe" "$settings_recipe"; do
      build_recipe "$recipe" "$target_arch" "$fixture" "$recipe-$target_arch"
    done
    runtime=$scratch/$runtime_recipe-$target_arch
    settings=$scratch/$settings_recipe-$target_arch

    for helper in omarchy-sudo-passwordless omarchy-security-functions; do
      cmp -s "$fixture/bin/$helper" "$settings/usr/bin/$helper" && [[ -x $settings/usr/bin/$helper ]] ||
        fail "$target_arch: $settings_recipe does not ship /usr/bin/$helper"
      [[ $(readlink "$settings/usr/share/omarchy/bin/$helper") == "/usr/bin/$helper" ]] ||
        fail "$target_arch: $settings_recipe does not link /usr/share/omarchy/bin/$helper"
    done
    cmp -s "$fixture/default/libalpm/hooks/05-omarchy-passwordless-revoke.hook" "$settings/$hook" &&
      [[ $(stat -c %a "$settings/$hook") == 644 ]] ||
      fail "$target_arch: $settings_recipe does not ship /$hook"
    cmp -s "$fixture/$boot_cleanup" "$settings/$boot_cleanup" ||
      fail "$target_arch: $settings_recipe does not ship /$boot_cleanup"
    [[ -x $runtime/usr/bin/omarchy-update && -f $runtime/usr/share/libalpm/hooks/00-omarchy-update-guard.hook ]] ||
      fail "$target_arch: $runtime_recipe lost its own commands or hooks"
    grep -Fxq omarchy-security-functions "$runtime.depends" ||
      fail "$target_arch: the $runtime_recipe package does not require omarchy-security-functions"
    grep -Fxq omarchy-security-functions "$settings.provides" ||
      fail "$target_arch: the $settings_recipe package does not provide omarchy-security-functions"

    assert_disjoint "$target_arch" "$runtime_recipe" "$settings_recipe"
    echo "PASS: $target_arch: $settings_recipe owns the sudo grant lifecycle and shares no file with $runtime_recipe"
  done
done

# An older pinned source (v4.0.6) has the grant command but no library or
# revocation hook: the stable runtime keeps shipping it, and settings neither
# takes it over nor provides the library.
legacy=$scratch/legacy/omarchy
mkdir -p "$(dirname "$legacy")"
cp -a "$fixture" "$legacy"
rm "$legacy/bin/omarchy-security-functions" "$legacy/default/libalpm/hooks/05-omarchy-passwordless-revoke.hook"
for target_arch in x86_64 aarch64; do
  for recipe in omarchy omarchy-settings; do
    build_recipe "$recipe" "$target_arch" "$legacy" "legacy-$recipe-$target_arch"
  done
  runtime=$scratch/legacy-omarchy-$target_arch
  settings=$scratch/legacy-omarchy-settings-$target_arch

  cmp -s "$legacy/bin/omarchy-sudo-passwordless" "$runtime/usr/bin/omarchy-sudo-passwordless" ||
    fail "$target_arch: omarchy dropped omarchy-sudo-passwordless for a source that predates the hook"
  [[ ! -e $settings/usr/bin/omarchy-sudo-passwordless && ! -e $settings/$hook ]] ||
    fail "$target_arch: omarchy-settings took over the grant command from a source that predates the hook"
  ! grep -Fxq omarchy-security-functions "$runtime.depends" ||
    fail "$target_arch: omarchy requires omarchy-security-functions from a source that does not ship it"
  ! grep -Fxq omarchy-security-functions "$settings.provides" ||
    fail "$target_arch: omarchy-settings provides omarchy-security-functions from a source that does not ship it"

  assert_disjoint "$target_arch" legacy-omarchy legacy-omarchy-settings
  echo "PASS: $target_arch: a source that predates the hook keeps the grant command in omarchy"
done
