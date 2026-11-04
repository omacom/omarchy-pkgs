#!/bin/bash
set -eo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
task_dir=$(mktemp -d)
trap 'rm -rf -- "$task_dir"' EXIT

build_tree="$task_dir/src/build-home"
mkdir -p "$build_tree/.config/nvim/lua/plugins" "$build_tree/.local/share/nvim/site"
printf 'build config\n' >"$build_tree/.config/nvim/origin"
printf 'build data\n' >"$build_tree/.local/share/nvim/origin"

mkdir -p "$task_dir/caller/config/nvim/lua/plugins" "$task_dir/caller/data/nvim/site"
printf 'caller config\n' >"$task_dir/caller/config/nvim/origin"
printf 'caller data\n' >"$task_dir/caller/data/nvim/origin"

for xdg_mode in caller unset; do
  (
    source "$root/pkgbuilds/omarchy-nvim/PKGBUILD"
    srcdir="$task_dir/src"
    startdir="$root/pkgbuilds/omarchy-nvim"
    pkgdir="$task_dir/pkg-$xdg_mode"
    export XDG_CONFIG_HOME="$task_dir/caller/config"
    export XDG_DATA_HOME="$task_dir/caller/data"
    if [[ $xdg_mode == unset ]]; then
      unset XDG_CONFIG_HOME XDG_DATA_HOME
    fi

    # A fresh package-only shell has no exports from build().
    package

    cmp "$build_tree/.config/nvim/origin" "$pkgdir/etc/skel/.config/nvim/origin"
    cmp "$build_tree/.local/share/nvim/origin" "$pkgdir/etc/skel/.local/share/nvim/origin"
    printf 'PASS: package() uses staged Neovim files with %s XDG paths\n' "$xdg_mode"
  )
done
