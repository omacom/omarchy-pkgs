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

# plan_slots <pkgbase map> <build-output dir> <already-published file>: map a
# resolved publish plan onto the (channel, architecture) slots it writes.
#
# stdin, one line per plan entry: "<package> <pkgbase> <arch> <channels>
# <publish_arches>". The map has one "<file> <pkgbase>" line per package, read
# from .PKGINFO. The skip file names "<package> <arch>" entries whose source is
# already published, so having no file to collect is not an error for them.
#
# stdout: one "<mirror> <arch> <file...>" line per slot, edge before rc before
# stable and x86_64 before aarch64.
#
# A plan entry owns the files whose .PKGINFO pkgbase is the one its recipe
# declares. Two entries may not declare one pkgbase for an architecture: both
# would publish the same filenames, and whichever artifact was collected last
# would replace the other. #1878 built linux-omarchy as pkgbase
# linux-omarchy-bore, so edge kept the 2.6 KB transitional stub and the 7.2.14
# kernel never shipped.
plan_slots() {
  local map=$1 output=$2 skip=${3:-/dev/null}
  local package base arch channels publish_arches mirror parch f count
  local -A base_owner=() slots=()

  while read -r package base arch channels publish_arches; do
    [[ -n "$package" ]] || continue
    if [[ -n "${base_owner["$base/$arch"]:-}" ]]; then
      echo "plan_slots: $package ($arch) and ${base_owner["$base/$arch"]} both build pkgbase $base" >&2
      return 1
    fi
    base_owner["$base/$arch"]=$package

    count=0
    for f in "$output/$arch"/*.pkg.tar.zst; do
      [[ -e "$f" ]] || continue
      [[ $(awk -v f="$f" '$1==f{print $2}' "$map") == "$base" ]] || continue
      count=$((count + 1))
      for mirror in ${channels//,/ }; do
        for parch in ${publish_arches//,/ }; do
          slots["$mirror/$parch"]+="$f "
        done
      done
    done

    # An entry that produced no file publishes nothing and reads as success.
    if (( count == 0 )) && ! grep -qxF "$package $arch" "$skip" 2>/dev/null; then
      echo "plan_slots: $package ($arch): no package file has pkgbase $base" >&2
      return 1
    fi
  done

  for base in "${!slots[@]}"; do
    printf '%s %s %s\n' "${base%/*}" "${base##*/}" "${slots[$base]}"
  done | sort -k1,1 -k2,2r
  return 0
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
