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

# The keyboard is a USB device on both architectures Omarchy ships.
[[ " ${arch[*]} " == *" x86_64 "* && " ${arch[*]} " == *" aarch64 "* ]] ||
  fail "the package builds for x86_64 and aarch64"

# Replacing the old names is what makes pacman take this over instead of
# leaving both binaries fighting for the same hidraw node.
[[ " ${conflicts[*]} " == *" keybackcon "* ]] || fail "the package conflicts with keybackcon"
[[ " ${replaces[*]} " == *" keybackcon "* ]] || fail "the package replaces keybackcon"
[[ " ${replaces[*]} " == *" kbd-rgb "* ]] || fail "the package replaces kbd-rgb"

# The recipe builds from the release tarball and packages its output, so the
# test stages the same tree makepkg would: a srcdir holding the extracted
# archive, with makepkg's own cwd convention (`cd` to srcdir before package()).
srcdir="$scratch/src"
pkgdir="$scratch/pkg"
mkdir -p "$srcdir" "$pkgdir"

# `name::url` keeps the archive under its local name; a bare URL keeps the URL's.
source_file="${source[0]%%::*}"
if [[ $source_file == http* ]]; then
  source_file="$package_dir/$(basename "$source_file")"
elif [[ ! -f $source_file ]]; then
  source_file="$package_dir/$source_file"
fi
bsdtar -xf "$source_file" -C "$srcdir" --no-same-owner

# The archive root is named after the repository, not the package.
build_tree=$(echo "$srcdir"/*/)
build_tree="${build_tree%/}"
[[ -d $build_tree ]] || fail "the release archive extracts to a single root"

(cd "$build_tree" && cargo build --release --locked)
for po in "$build_tree"/po/*.po; do
  _lang="${po##*/}"
  _lang="${_lang%.po}"
  mkdir -p "$build_tree/gui/locale/${_lang}/LC_MESSAGES"
  msgfmt -o "$build_tree/gui/locale/${_lang}/LC_MESSAGES/ilutex.mo" "$po"
done

(cd "$srcdir" && package)

echo "ok - ilutex"
