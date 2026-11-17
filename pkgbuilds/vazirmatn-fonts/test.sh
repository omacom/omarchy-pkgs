#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
recipe="$repo_root/pkgbuilds/vazirmatn-fonts"
workdir=$(mktemp -d)
trap 'rm -f /etc/fonts/conf.d/50-omarchy.conf; fc-cache --force >/dev/null 2>&1 || true; rm -rf "$workdir"' EXIT

if [[ $EUID -ne 0 ]]; then
  echo "Run this test as root (the package test workflow does)." >&2
  exit 1
fi

command -v makepkg >/dev/null
command -v pacman >/dev/null
command -v fc-match >/dev/null
command -v curl >/dev/null

pacman -S --needed --noconfirm fontconfig git base-devel curl

# Build as an unprivileged user; makepkg refuses to run as root.
install -d -o nobody -g nobody "$workdir/build" "$workdir/home"
cp "$recipe/PKGBUILD" "$workdir/build/"
chown -R nobody:nobody "$workdir/build" "$workdir/home"
runuser -u nobody -- env HOME="$workdir/home" bash -c 'cd "$1" && makepkg --nodeps --noconfirm --clean' _ "$workdir/build"

package=$(find "$workdir/build" -maxdepth 1 -type f -name 'vazirmatn-fonts-*.pkg.tar.*' ! -name '*.sig' -print -quit)
[[ -n $package ]] || { echo "Package build did not produce an installable archive" >&2; exit 1; }

pacman -U --noconfirm "$package"
# Exercise the same system-ui -> Liberation Sans mapping used by Omarchy.
curl -fsSL "https://raw.githubusercontent.com/omacom/omarchy/a948d8a6871f446b335258c827648ac5f4e9428b/default/fontconfig/conf.avail/50-omarchy.conf" \
  -o /etc/fonts/conf.d/50-omarchy.conf
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
