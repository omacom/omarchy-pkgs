#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

fail() {
  echo "not ok - $1" >&2
  exit 1
}

source "$package_dir/PKGBUILD"

[[ ${source[0]} == *"#tag=$pkgver" ]] || fail "the daemon builds from its release tag"
[[ " ${depends[*]} " == *" power-profiles-daemon>=$pkgver "* ]] ||
  fail "it requires at least the release it was built from, so an Arch update does not block upgrades"
grep -q '/sys/class/platform-profile/platform-profile-0/profile' "$package_dir/0001-platform-profile-use-the-class-device.patch" ||
  fail "the patch reads the platform-profile class device"
grep -Fxq 'ExecStart=' "$package_dir/10-surface-pro-11.conf" ||
  fail "the drop-in clears the packaged ExecStart before replacing it"
grep -Fxq "ExecStart=/usr/lib/$pkgname/power-profiles-daemon" "$package_dir/10-surface-pro-11.conf" ||
  fail "the drop-in runs the installed binary"

echo "ok - power-profiles-daemon-surface-pro-11 selects its patched daemon through a drop-in"
