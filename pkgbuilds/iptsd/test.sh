#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

fail() {
  echo "not ok - $1" >&2
  exit 1
}

source "$package_dir/PKGBUILD"

[[ $_commit == a83bc1232f7096f8b33b50fdbda249cd640de670 ]] ||
  fail "iptsd builds from the pinned v3.1.0 commit"
[[ ${source[0]} == *"#commit=${_commit}" ]] ||
  fail "the source is fetched at the pinned commit"
grep -q -- '--wrap-mode=nofallback' "$package_dir/PKGBUILD" ||
  fail "iptsd links against Arch libraries instead of bundled copies"
grep -q -- '-Ddebug_tools= ' "$package_dir/PKGBUILD" ||
  fail "the SDL and Cairo debug tools are not built"
for dependency in fmt libinih spdlog; do
  [[ " ${depends[*]} " == *" $dependency "* ]] || fail "iptsd depends on $dependency at runtime"
done
for dependency in cli11 cmake eigen microsoft-gsl; do
  [[ " ${makedepends[*]} " == *" $dependency "* ]] || fail "iptsd builds with $dependency"
done

[[ " ${arch[*]} " == " aarch64 " ]] ||
  fail "iptsd is aarch64-only, leaving Intel Surfaces to the linux-surface package"

grep -q "sed -i 's/ACTION==\"add\"/ACTION!=\"remove\"/'" "$package_dir/PKGBUILD" ||
  fail "a udev change event, such as pacman's rule reload, keeps iptsd running"

echo "ok - iptsd builds pinned upstream source against Arch libraries"
