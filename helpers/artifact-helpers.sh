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

# build_contract_key [repo]: bind a PR artifact to the base-branch tools that
# produced it. A package tree alone is not enough: a later fix to build/build.sh
# or its helpers must not reuse bytes made before that fix. Keep this narrower
# than the whole commit so unrelated docs and package changes retain reuse.
build_contract_key() {
  local root=${1:-.} objects
  objects=$(git -C "$root" rev-parse \
    HEAD:bin/build HEAD:bin/build-matrix HEAD:helpers HEAD:build \
    HEAD:.github/workflows/build-pr.yml) || return
  printf 'v1-%s\n' "$(printf '%s\n' "$objects" | sha256sum | cut -d' ' -f1)"
}

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

# unpack_packages <artifact dir> <dest>: the packages an unzipped artifact
# carried, into <dest>. Packed artifacts hold packages.tar; artifacts from
# builds before packing hold the bare files. The bare form can go once
# those artifacts have expired (7-day retention).
unpack_packages() {
  local src=$1 dest=$2 files=()
  mkdir -p "$dest"
  if [[ -f "$src/packages.tar" ]]; then
    tar -xf "$src/packages.tar" -C "$dest"
    return 0
  fi
  mapfile -t files < <(package_files "$src")
  (( ${#files[@]} )) || { echo "unpack_packages: nothing to unpack in $src" >&2; return 1; }
  cp -- "${files[@]}" "$dest/"
}
