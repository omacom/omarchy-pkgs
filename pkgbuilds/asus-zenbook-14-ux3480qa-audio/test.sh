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

# Each model gets a top-level Syntax 6 UCM profile restating the T14s profile
# and setting the WSA digital volumes to 100% on every boot.
t14s=/usr/share/alsa/ucm2/Qualcomm/x1e80100/LENOVO-T14s.conf
for model in UX3480QA UX3480QAB; do
  ucm="$pkgdir/usr/share/alsa/ucm2/conf.d/x1e80100/ASUSTeKCOMPUTERINC.-Zenbook14$model-1.0-$model.conf"
  [[ -f $ucm && ! -L $ucm ]] || fail "the $model profile is installed as a regular file"
  if command -v pacman &>/dev/null && pacman -Qq alsa-ucm-conf &>/dev/null && [[ -f $t14s ]]; then
    while IFS= read -r line; do
      [[ -z ${line//[[:space:]]/} || $line == \#* ]] && continue
      grep -qxF -- "$line" "$ucm" || fail "the $model profile restates the T14s profile: $line"
    done <"$t14s"
  fi
  for c in "WSA WSA_RX0" "WSA WSA_RX1"; do
    sed -n '/^FixedBootSequence \[/,/^\]/p' "$ucm" | grep -qF "cset \"name='$c Digital Volume' 100%\"" ||
      fail "the $model profile sets $c Digital Volume to its ceiling on every boot"
  done
done

wp="$pkgdir/usr/share/wireplumber/wireplumber.conf.d/60-asus-zenbook-14-ux3480qa-soft-volume.conf"
[[ -f $wp ]] || fail "the WirePlumber soft-volume rule is installed"
for model in UX3480QA UX3480QAB; do
  grep -q "api.alsa.card.longname = \"ASUSTeKCOMPUTERINC.-Zenbook14$model-1.0-$model\"" "$wp" ||
    fail "the soft-volume rule matches $model's card longname"
done
grep -q 'api.alsa.soft-mixer = true' "$wp" || fail "the soft-volume rule switches to software volume"

echo "ok - asus-zenbook-14-ux3480qa-audio"
