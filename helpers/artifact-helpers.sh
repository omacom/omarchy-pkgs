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

# unpack_packages <artifact dir> <dest>: the packages an unzipped artifact
# carried in its packages.tar, into <dest>. The tar is a build's output, so
# it is checked before anything is extracted: plain files only (no links,
# directories or devices), each at the top level, named as a package, once.
unpack_packages() {
  local src=$1 dest=$2 tarball=$1/packages.tar types names
  [[ -f $tarball && ! -L $tarball ]] || { echo "unpack_packages: no packages.tar in $src" >&2; return 1; }
  types=$(tar -tvf "$tarball" | cut -c1 | sort -u) || { echo "unpack_packages: unreadable $tarball" >&2; return 1; }
  names=$(tar -tf "$tarball")
  if [[ -z $names || $types != "-" ]] || grep -qvE '^[a-zA-Z0-9@_+][a-zA-Z0-9@._+:~-]*\.pkg\.tar\.zst$' <<<"$names" \
    || [[ -n $(sort <<<"$names" | uniq -d) ]]; then
    echo "unpack_packages: $tarball holds something other than package files" >&2
    return 1
  fi
  mkdir -p "$dest"
  tar -xf "$tarball" -C "$dest" --no-same-owner
}
