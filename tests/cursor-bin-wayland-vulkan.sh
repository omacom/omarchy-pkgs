#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
snippet="$ROOT/pkgbuilds/cursor-bin/wayland-vulkan.sh"
pkgbuild="$ROOT/pkgbuilds/cursor-bin/PKGBUILD"

# Run the snippet the way the launcher does: set -euo pipefail, with the
# electronflags and codeflags arrays it has built from the flags files.
flags_after() {
  local electron=$1 code=$2
  bash -c '
    set -euo pipefail
    electronflags=()
    codeflags=()
    [[ -z $1 ]] || IFS="|" read -r -a electronflags <<<"$1"
    [[ -z $2 ]] || IFS="|" read -r -a codeflags <<<"$2"
    source "$3"
    IFS="|"
    printf "%s / %s\n" "${electronflags[*]}" "${codeflags[*]}"
  ' bash "$electron" "$code" "$snippet"
}

expect() {
  local description=$1 electron=$2 code=$3 expected=$4 actual
  actual=$(flags_after "$electron" "$code")
  if [[ $actual != "$expected" ]]; then
    printf 'not ok - %s\n  expected: %s\n  actual:   %s\n' "$description" "$expected" "$actual" >&2
    exit 1
  fi
  printf 'ok - %s\n' "$description"
}

expect "no flags files disable Vulkan" \
  "" "" "--disable-features=Vulkan / "
expect "other electron flags are kept" \
  "--ozone-platform=wayland|--enable-wayland-ime" "" \
  "--ozone-platform=wayland|--enable-wayland-ime|--disable-features=Vulkan / "
expect "an electron --disable-features list gains Vulkan" \
  "--disable-features=Foo" "" "--disable-features=Foo,Vulkan / "
expect "a cursor-flags --disable-features list gains Vulkan instead of being overridden" \
  "" "--disable-features=Bar" " / --disable-features=Bar,Vulkan"
expect "Vulkan already listed is not added twice" \
  "--disable-features=Vulkan,Foo" "" "--disable-features=Vulkan,Foo / "
expect "an explicit X11 platform keeps Vulkan available" \
  "--ozone-platform=x11" "" "--ozone-platform=x11 / "
expect "an explicit X11 platform hint keeps Vulkan available" \
  "" "--ozone-platform-hint=x11" " / --ozone-platform-hint=x11"

# The x86_64 build ships the snippet and inserts it into the launcher.
grep -Fxq 'wayland-vulkan.sh)' "$pkgbuild"
grep -Fq "e cat '\${srcdir}/wayland-vulkan.sh'\" \"\${pkgdir}\"/usr/share/cursor/cursor" "$pkgbuild"
grep -Fq "grep -q 'disable-features=Vulkan' \"\${pkgdir}\"/usr/share/cursor/cursor || return 1" "$pkgbuild"
printf 'ok - PKGBUILD inserts the snippet into the launcher\n'
