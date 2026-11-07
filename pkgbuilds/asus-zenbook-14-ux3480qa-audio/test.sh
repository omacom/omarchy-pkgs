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

for model in UX3480QA UX3480QAB; do
  ucm="$pkgdir/usr/share/alsa/ucm2/conf.d/x1e80100/ASUSTeKCOMPUTERINC.-Zenbook14$model-1.0-$model.conf"
  [[ -f $ucm ]] || fail "the $model profile is named after the card's long name"
  grep -qxF 'Include.t14s.File "/Qualcomm/x1e80100/LENOVO-T14s.conf"' "$ucm" ||
    fail "the $model profile includes the T14s profile"
done

# Where alsa-ucm-conf is installed, check that the profile it names still
# exists and still drives two speakers.
t14s=/usr/share/alsa/ucm2/Qualcomm/x1e80100/LENOVO-T14s.conf
if pacman -Qq alsa-ucm-conf &>/dev/null; then
  [[ -f $t14s ]] || fail "alsa-ucm-conf ships the T14s profile"
  grep -qF '/codecs/wsa884x/two-speakers/' "$t14s" || fail "the T14s profile drives two WSA884x speakers"
fi

echo "ok - asus-zenbook-14-ux3480qa-audio"
