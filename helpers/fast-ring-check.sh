#!/bin/bash
# The fast ring's compatibility check. A package builds once, against edge,
# and the fast ring publishes that same file to rc and stable at once,
# ahead of the Arch snapshot it was built against. That is only safe when
# what it ships runs on the older libraries those channels carry.
#
# bin/check-fast-ring runs this inside a container built from the edge
# builder image:
#
#   fast-ring-check.sh prepare <channel> <arch>   point pacman at <channel>
#   fast-ring-check.sh check <package file>...    install and inspect
#
# `check` installs the packages from the channel's own repositories and
# fails on:
#   - a dependency the channel cannot satisfy;
#   - an ELF whose libraries or versioned symbols the channel lacks
#     (`ldd -r`);
#   - an ELF linking Qt or libpython, and any file under
#     /usr/lib/python3.X: those break on a dependency update without a
#     missing symbol to show it (Qt's private API and plugin version check,
#     Python's versioned module path), so they need rebuilds the fast ring
#     cannot give them.
# The rebuild_on half of the rule is metadata, enforced by
# validate_package_metadata.

set -euo pipefail

# Where each channel's Arch packages come from, as in build/Dockerfile.
# Arch Linux ARM has no snapshots: every channel follows the live mirror,
# so on aarch64 only the Omarchy repository differs between channels.
channel_mirror() { # channel_mirror <channel> <arch>
  case "$2:$1" in
    x86_64:stable) echo 'https://stable-mirror.omarchy.org/$repo/os/$arch' ;;
    x86_64:rc) echo 'https://rc-mirror.omarchy.org/$repo/os/$arch' ;;
    x86_64:edge) echo 'https://mirror.omarchy.org/$repo/os/$arch' ;;
    aarch64:*) echo 'https://fl.us.mirror.archlinuxarm.org/aarch64/$repo' ;;
    *) return 1 ;;
  esac
}

# ldd_problems <shared|executable>: the lines of `ldd -r` output on stdin
# that mean the binary cannot run here. An unversioned undefined symbol in
# a shared library is normal for a plugin, whose host process provides it;
# a versioned one names a library that was found and lacks the symbol.
ldd_problems() {
  local kind=$1 line
  while IFS= read -r line; do
    case "$line" in
      *"=> not found"*) printf '%s\n' "$line" ;;
      *"version \`"*"' not found"*) printf '%s\n' "$line" ;;
      *"undefined symbol: "*", version "*) printf '%s\n' "$line" ;;
      *"undefined symbol: "*) [[ $kind == executable ]] && printf '%s\n' "$line" ;;
    esac
  done
  return 0
}

# rebuild_sonames: NEEDED entries, one per line on stdin, that tie a binary
# to an exact dependency version.
rebuild_sonames() {
  grep -E '^(libQt[0-9]|libpython3)' || true
}

prepare() {
  local channel=$1 arch=$2 server
  server=$(channel_mirror "$channel" "$arch") || { echo "unknown channel $channel for $arch" >&2; exit 2; }
  printf 'Server = %s\n' "$server" > /etc/pacman.d/mirrorlist
  sed -i '/^\[omarchy\]/,/^$/d' /etc/pacman.conf
  sed -i "/^\[core\]$/i [omarchy]\nSigLevel = Required DatabaseOptional\nServer = https://pkgs.omarchy.org/$channel/$arch\n" /etc/pacman.conf
  # -uu: a channel's snapshot is older than the image's, so this downgrades.
  pacman -Syuu --noconfirm
}

# inspect_files: the installed paths on stdin, one per line. Prints a FAIL
# line for each file that would break on this system's libraries.
inspect_files() {
  local machine failed=0 path kind out needed
  local -a paths=() dirs=()
  mapfile -t paths
  machine=$(readelf -h /usr/bin/bash | sed -n 's/^ *Machine: *//p')

  # Vendor launchers often add their own library directory to
  # LD_LIBRARY_PATH; resolve bundled libraries the same way.
  mapfile -t dirs < <(printf '%s\n' "${paths[@]}" | grep -E '\.so(\.[0-9]+)*$' | xargs -r -n1 dirname | sort -u)
  local LD_LIBRARY_PATH
  LD_LIBRARY_PATH=$(IFS=:; echo "${dirs[*]}")
  export LD_LIBRARY_PATH

  for path in "${paths[@]}"; do
    if [[ $path =~ ^/usr/lib/python3\.[0-9]+/ ]]; then
      echo "FAIL: $path is a Python module; it breaks when Python's minor version moves"
      failed=1
      continue
    fi
    [[ -f $path && ! -L $path && $path != /usr/lib/debug/* ]] || continue
    [[ "$(head -c4 "$path" | od -An -c | tr -d ' ')" == '177ELF' ]] || continue
    # Bundled foreign-architecture code (box64's x86 libraries, firmware).
    [[ "$(readelf -h "$path" 2>/dev/null | sed -n 's/^ *Machine: *//p')" == "$machine" ]] || continue
    # Static binaries have no dynamic section to check.
    readelf -d "$path" 2>/dev/null | grep -q NEEDED || continue

    needed=$(readelf -d "$path" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | rebuild_sonames)
    if [[ -n $needed ]]; then
      echo "FAIL: $path links $(echo $needed), which needs rebuilds the fast ring cannot give it"
      failed=1
      continue
    fi

    kind=shared
    readelf -l "$path" 2>/dev/null | grep -q 'INTERP' && kind=executable
    out=$(ldd -r "$path" 2>&1 | ldd_problems "$kind")
    if [[ -n $out ]]; then
      echo "FAIL: $path"
      sed 's/^/    /' <<<"$out"
      failed=1
    fi
  done
  return "$failed"
}

check() {
  local file
  local -a names=()
  # Scriptlets would need a booted system; their output is not under test.
  if ! pacman -U --noconfirm --noscriptlet --ask 4 "$@"; then
    echo "FAIL: the channel cannot satisfy the packages' dependencies"
    return 1
  fi
  for file in "$@"; do
    names+=("$(bsdtar -xOf "$file" .PKGINFO | sed -n 's/^pkgname = //p')")
  done
  pacman -Qlq "${names[@]}" | grep -v '/$' | inspect_files || return 1
  echo "PASS: ${names[*]} run on this channel's libraries"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  command=${1:-}
  shift || true
  case "$command" in
    prepare) prepare "$@" ;;
    check) check "$@" ;;
    *) echo "usage: $0 prepare <channel> <arch> | check <package file>..." >&2; exit 2 ;;
  esac
fi
