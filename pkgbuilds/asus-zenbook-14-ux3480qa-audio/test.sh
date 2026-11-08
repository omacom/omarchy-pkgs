#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

source "$package_dir/PKGBUILD"
[[ " ${arch[*]} " == " aarch64 " && " ${groups[*]} " == *" omarchy-platform-qualcomm "* ]] ||
  fail "the package is tagged Qualcomm-only for aarch64"

pkgdir="$scratch/pkg"
(cd "$package_dir" && package)

ucm="$pkgdir/usr/share/alsa/ucm2/conf.d/x1e80100/ASUSTeKCOMPUTERINC.-Zenbook14UX3480QA-1.0-UX3480QA.conf"
# A symlink, not a wrapper: a wrapper declares its own Syntax, and UCM
# rejects the T14s profile's Syntax 6 macros under a wrapper's Syntax 4.
[[ -L $ucm ]] || fail "the profile is named after the card's long name and is a symlink"
[[ $(readlink "$ucm") == ../../Qualcomm/x1e80100/LENOVO-T14s.conf ]] ||
  fail "the profile links to the T14s profile"

# Where alsa-ucm-conf is installed, check that the profile it names still
# exists and still drives two speakers.
t14s=/usr/share/alsa/ucm2/Qualcomm/x1e80100/LENOVO-T14s.conf
if pacman -Qq alsa-ucm-conf &>/dev/null; then
  [[ -f $t14s ]] || fail "alsa-ucm-conf ships the T14s profile"
  grep -qF '/codecs/wsa884x/two-speakers/' "$t14s" || fail "the T14s profile drives two WSA884x speakers"
fi

echo "ok - asus-zenbook-14-ux3480qa-audio"
