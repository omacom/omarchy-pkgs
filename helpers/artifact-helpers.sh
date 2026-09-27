#!/bin/bash
# Package files cross from a PR build to publish.yml as one GitHub Actions
# artifact. actions/upload-artifact rejects any path containing ':', and a
# package with an epoch is named `name-1:ver-rel-arch.pkg.tar.zst` by
# makepkg. So the files ride inside a tar with a plain name and keep their
# own names untouched: pacman clients and bin/publish-artifact both rely on
# the filename matching PKGINFO.
#
# Both functions run under the workflow's `bash -e`: nothing in them may
# return non-zero except the final failure.

# package_files <dir>: the *.pkg.tar.zst directly in <dir>, one per line.
# Signatures and the scratch database next to them are not packages.
package_files() {
  local f
  for f in "$1"/*.pkg.tar.zst; do
    [[ -e "$f" ]] && printf '%s\n' "$f"
  done
  return 0
}

# pack_packages <dir> <tar>: every package in <dir> into <tar>.
pack_packages() {
  local dir=$1 out=$2 files=()
  mapfile -t files < <(package_files "$dir")
  (( ${#files[@]} )) || { echo "pack_packages: no *.pkg.tar.zst in $dir" >&2; return 1; }
  tar -cf "$out" -C "$dir" -- "${files[@]##*/}"
}

# unpack_packages <artifact dir or zip> <empty dest>: accept packed or legacy
# bare artifacts, copying only regular package files through the checked helper.
unpack_packages() {
  local helper="$(realpath "${BASH_SOURCE[0]%/*}")/unpack-package-artifact.py"
  mkdir -p "$2"
  python3 "$helper" "$1" "$2"
}
