#!/bin/bash
# Advisory files follow the exact packages selected for remote channel carry.
# Uses a local directory as the rclone remote; no network or signing key.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
source "$ROOT/helpers/advisory-helpers.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pkg="demo-1.0.0-1-x86_64.pkg.tar.zst"
adv="${pkg%.pkg.tar.*}.advisory.json"
[[ "$(advisory_path_for_package_file "$T" "$pkg")" == "$T/$adv" ]]
[[ "$(advisory_artifact_name demo 1.0.0 1 x86_64)" == "$adv" ]]

src="$T/remote/edge/x86_64"
dest="$T/download"
mkdir -p "$src" "$dest"
printf 'package\n' > "$src/$pkg"
printf 'advisory-v1\n' > "$src/$adv"
printf 'signature-v1\n' > "$src/$adv.sig"
plain="missing-1.0.0-1-any.pkg.tar.zst"
printf 'no advisory yet\n' > "$src/$plain"
printf 'unselected\n' > "$src/other-1.0.0-1-x86_64.advisory.json"

advisory_copy_package_files "$src" "$dest" "$pkg" "$plain"
for file in "$pkg" "$adv" "$adv.sig" "$plain"; do
  cmp "$src/$file" "$dest/$file"
done
[[ $(find "$dest" -type f | wc -l) -eq 4 ]]
echo "PASS: selected packages carry their advisory and signature; absent advisories are optional"

# No selection must not download the whole channel.
empty="$T/empty"
mkdir -p "$empty"
advisory_copy_package_files "$src" "$empty"
[[ -z $(find "$empty" -type f -print -quit) ]]
echo "PASS: an empty selection carries nothing"

# A package can carry an unsigned advisory during a local proof run.
rm "$src/$adv.sig"
unsigned="$T/unsigned"
advisory_copy_package_files "$src" "$unsigned" "$pkg"
cmp "$src/$adv" "$unsigned/$adv"
[[ ! -e "$unsigned/$adv.sig" ]]
echo "PASS: a missing advisory signature does not block package carry"
