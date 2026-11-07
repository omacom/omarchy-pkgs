#!/bin/bash
# Build both runtimes from a synthetic source tree: a source with the TRIM
# setup ships its pacman hook, the hook's Exec target and the backlog unit
# together, with the unit wanted by multi-user.target, and shares no file with
# settings. An older pinned source ships none of them.
set -euo pipefail

BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fixture=$scratch/src/omarchy

mapfile -t files < "$BUILD_ROOT/tests/fixtures/settings-source-files"
files+=(
  bin/omarchy-update
  bin/omarchy-apply-trim
  default/libalpm/hooks/00-omarchy-update-guard.hook
  default/libalpm/hooks/10-omarchy-hyprland-reload-pause.hook
  default/libalpm/hooks/90-omarchy-hyprland-reload-resume.hook
  default/libalpm/hooks/95-omarchy-trim.hook
  default/systemd/system/omarchy-trim-backlog.service
  install/omarchy-base.packages
  migrations/1788163635.sh
  themes/fixture/colors.toml
  shell/shell.qml
  version
)
for path in "${files[@]}"; do
  mkdir -p "$(dirname "$fixture/$path")"
  printf 'fixture for %s\n' "$path" > "$fixture/$path"
done
cp "$BUILD_ROOT/tests/fixtures/settings-boot/omarchy_hooks-v4.0.4.conf" "$fixture/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
printf 'Exec = /usr/bin/omarchy-apply-trim\n' >"$fixture/default/libalpm/hooks/95-omarchy-trim.hook"
printf 'ExecStart=/usr/bin/omarchy-apply-trim --backlog\n' >"$fixture/default/systemd/system/omarchy-trim-backlog.service"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

hook=usr/share/libalpm/hooks/95-omarchy-trim.hook
unit=usr/lib/systemd/system/omarchy-trim-backlog.service
wants=usr/lib/systemd/system/multi-user.target.wants/omarchy-trim-backlog.service

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
rm "$legacy/bin/omarchy-apply-trim" "$legacy/default/libalpm/hooks/95-omarchy-trim.hook" "$legacy/default/systemd/system/omarchy-trim-backlog.service"

for pair in omarchy-dev:omarchy-settings-dev omarchy:omarchy-settings; do
  runtime_recipe=${pair%%:*} settings_recipe=${pair#*:}
  for target_arch in x86_64 aarch64; do
    build_recipe "$runtime_recipe" "$target_arch" "$fixture" "$runtime_recipe-$target_arch"
    build_recipe "$settings_recipe" "$target_arch" "$fixture" "$settings_recipe-$target_arch"
    runtime=$scratch/$runtime_recipe-$target_arch
    settings=$scratch/$settings_recipe-$target_arch

    [[ -x $runtime/usr/bin/omarchy-apply-trim ]] ||
      fail "$target_arch: $runtime_recipe does not ship the hook's Exec target"
    cmp -s "$fixture/default/libalpm/hooks/95-omarchy-trim.hook" "$runtime/$hook" &&
      [[ $(stat -c %a "$runtime/$hook") == 644 ]] ||
      fail "$target_arch: $runtime_recipe does not ship /$hook"
    cmp -s "$fixture/default/systemd/system/omarchy-trim-backlog.service" "$runtime/$unit" ||
      fail "$target_arch: $runtime_recipe does not ship /$unit"
    [[ $(readlink "$runtime/$wants") == ../omarchy-trim-backlog.service ]] ||
      fail "$target_arch: $runtime_recipe does not make multi-user.target want the backlog unit"
    overlap=$(comm -12 <(cd "$runtime" && find . ! -type d | sort) <(cd "$settings" && find . ! -type d | sort))
    [[ -z $overlap ]] || fail "$target_arch: shipped by both $runtime_recipe and $settings_recipe:"$'\n'"$overlap"

    build_recipe "$runtime_recipe" "$target_arch" "$legacy" "legacy-$runtime_recipe-$target_arch"
    runtime=$scratch/legacy-$runtime_recipe-$target_arch
    [[ ! -e $runtime/$hook && ! -e $runtime/$unit && ! -L $runtime/$wants ]] ||
      fail "$target_arch: $runtime_recipe ships TRIM files from a source that predates them"
    [[ -f $runtime/usr/share/libalpm/hooks/00-omarchy-update-guard.hook ]] ||
      fail "$target_arch: $runtime_recipe lost its other hooks"
    echo "PASS: $target_arch: $runtime_recipe ships the TRIM hook with its Exec target and backlog unit, and only from a source that has them"
  done
done
