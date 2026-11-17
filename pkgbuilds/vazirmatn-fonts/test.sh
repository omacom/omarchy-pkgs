#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
recipe="$repo_root/pkgbuilds/vazirmatn-fonts"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

if [[ $EUID -ne 0 ]]; then
  echo "Run this test as root (the package test workflow does)." >&2
  exit 1
fi

command -v makepkg >/dev/null
command -v pacman >/dev/null
command -v fc-match >/dev/null

# Build as an unprivileged user; makepkg refuses to run as root.
install -d -o nobody -g nobody "$workdir/build"
cp "$recipe/PKGBUILD" "$workdir/build/"
chown nobody:nobody "$workdir/build/PKGBUILD"
runuser -u nobody -- bash -c 'cd "$1" && makepkg --syncdeps --noconfirm --clean' _ "$workdir/build"

package=$(find "$workdir/build" -maxdepth 1 -type f -name 'vazirmatn-fonts-*.pkg.tar.*' ! -name '*.sig' -print -quit)
[[ -n $package ]] || { echo "Package build did not produce an installable archive" >&2; exit 1; }

pacman -U --noconfirm "$package"
fc-cache --force

match_family() {
  fc-match -f '%{family}\n' "$1" | head -n1 | cut -d, -f1
}

persian_sans=$(match_family 'sans-serif:lang=fa')
english_sans=$(match_family 'sans-serif:lang=en')
persian_mono=$(match_family 'monospace:lang=fa')
system_ui=$(match_family 'system-ui:lang=fa')

[[ "$persian_sans" == "Vazirmatn" ]] || {
  echo "Expected Persian sans-serif to resolve to Vazirmatn; got: $persian_sans" >&2
  exit 1
}
[[ "$system_ui" == "Vazirmatn" ]] || {
  echo "Expected Persian system-ui to resolve to Vazirmatn; got: $system_ui" >&2
  exit 1
}
[[ "$english_sans" != "Vazirmatn" ]] || {
  echo "English sans-serif unexpectedly resolves to Vazirmatn" >&2
  exit 1
}
[[ "$persian_mono" != "Vazirmatn" ]] || {
  echo "Persian monospace unexpectedly resolves to Vazirmatn" >&2
  exit 1
}

printf 'PASS Persian sans-serif: %s\n' "$persian_sans"
printf 'PASS Persian system-ui: %s\n' "$system_ui"
printf 'PASS English sans-serif remains: %s\n' "$english_sans"
printf 'PASS Persian monospace remains: %s\n' "$persian_mono"
