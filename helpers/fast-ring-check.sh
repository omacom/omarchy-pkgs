#!/bin/bash
# The fast ring's compatibility check. A package builds once, against edge,
# and the fast ring publishes that same file to rc and stable at once,
# ahead of the Arch snapshot it was built against. That is only safe when
# what it ships runs on the older libraries those channels carry.
#
# bin/check-fast-ring runs this inside containers built from the edge
# builder image, one per channel, edge included:
#
#   fast-ring-check.sh prepare <channel> <arch>        point pacman at <channel>
#   fast-ring-check.sh check <results> <package file>... install and inspect
#
# `check` installs the packages from the channel's own repositories and
# writes one problem per line to <results>, as <kind>TAB<path>TAB<detail>:
#   rule  fails wherever it happens: a dependency the channel cannot
#         satisfy, an ELF linking Qt or libpython, a file under
#         /usr/lib/python3.X. Those break on a dependency update without a
#         missing symbol to show it (Qt's private API and plugin version
#         check, Python's versioned module path), so they need rebuilds the
#         fast ring cannot give them.
#   link  an ELF whose libraries, symbol versions or interpreter are
#         missing (`ldd -r`). Fails only where edge does not show the same
#         line: an optional plugin whose library nobody installs is no
#         different on stable.
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

# ldd_problems <strict|plugin>: the lines of `ldd -r` output on stdin that
# mean the binary cannot run here. A plugin's unversioned undefined symbols
# are normal: its host process provides them. A versioned one names a
# library that was found and lacks the symbol, so it fails either way.
ldd_problems() {
  local kind=$1 line
  while IFS= read -r line; do
    case "$line" in
      *"=> not found"*) printf '%s\n' "$line" ;;
      *"version \`"*"' not found"*) printf '%s\n' "$line" ;;
      *"undefined symbol: "*", version "*) printf '%s\n' "$line" ;;
      *"undefined symbol: "*) [[ $kind == strict ]] && printf '%s\n' "$line" ;;
    esac
  done
  return 0
}

# elf_kind <path> <readelf -l output>: strict for executables and for
# libraries directly in /usr/lib, which other programs link; plugin for a
# shared object anywhere else, which is loaded into a host.
elf_kind() {
  if [[ $2 == *"INTERP"* || $1 =~ ^/usr/lib/[^/]+$ ]]; then
    echo strict
  else
    echo plugin
  fi
}

# rebuild_sonames: NEEDED entries, one per line on stdin, that tie a binary
# to an exact dependency version.
rebuild_sonames() {
  grep -E '^(libQt[0-9]|libpython3)' || true
}

prepare() {
  local channel=$1 arch=$2 server
  local -a foreign=()
  server=$(channel_mirror "$channel" "$arch") || { echo "unknown channel $channel for $arch" >&2; exit 2; }
  printf 'Server = %s\n' "$server" > /etc/pacman.d/mirrorlist
  sed -i '/^\[omarchy\]/,/^$/d' /etc/pacman.conf
  sed -i "/^\[core\]$/i [omarchy]\nSigLevel = Required DatabaseOptional\nServer = https://pkgs.omarchy.org/$channel/$arch\n" /etc/pacman.conf
  # -yy: the image's databases are edge's and newer than the channel's, so
  # a plain -y would call them current and keep them.
  pacman -Syy --noconfirm
  # A package edge added and the channel does not have yet would otherwise
  # stay installed and satisfy a dependency no machine on the channel can.
  # Removed first: its dependencies could hold back the downgrade.
  mapfile -t foreign < <(pacman -Qmq || true)
  if (( ${#foreign[@]} )); then
    pacman -Rdd --noconfirm "${foreign[@]}"
  fi
  # -uu: a channel's snapshot is older than the image's, so this downgrades.
  pacman -Suu --noconfirm
}

# bundled_dir <binary> <directory>...: of the directories holding a bundled
# copy of one library, the one nearest the binary, where its own launcher
# would look.
bundled_dir() {
  local binary=$1 dir best="" best_len=-1 prefix
  shift
  for dir in "$@"; do
    prefix=$dir
    until [[ ${binary%/*}/ == "$prefix"/* || -z $prefix ]]; do prefix=${prefix%/*}; done
    # Nearest shared ancestor first; among equals, the shallower copy.
    if (( ${#prefix} > best_len || (${#prefix} == best_len && ${#dir} < ${#best}) )); then
      best=$dir best_len=${#prefix}
    fi
  done
  printf '%s\n' "$best"
}

# problem <kind> <path> <detail>...: one record per detail.
problem() {
  local kind=$1 path=$2 detail
  shift 2
  for detail in "$@"; do
    printf '%s\t%s\t%s\n' "$kind" "$path" "$detail"
  done
}

# inspect_files: the installed paths on stdin, one per line. Prints a
# problem record for everything that would break on this system.
inspect_files() {
  local machine path kind out needed dyn prog interp soname dir
  local -a paths=() dirs=() lines=() copies=()
  local -A shipped=()
  mapfile -t paths
  machine=$(readelf -h /usr/bin/bash | sed -n 's/^ *Machine: *//p')

  # Libraries the package carries itself: soname -> directories, one per
  # line. Vendor launchers put their own directory on LD_LIBRARY_PATH, so a
  # binary that fails against the system's copy is checked again with the
  # package's own.
  for path in "${paths[@]}"; do
    [[ $path =~ \.so(\.[0-9]+)*$ ]] && shipped[${path##*/}]+="${path%/*}"$'\n'
  done

  for path in "${paths[@]}"; do
    if [[ $path =~ ^/usr/lib/python3\.[0-9]+/ ]]; then
      problem rule "$path" "a Python module, which breaks when Python's minor version moves"
      continue
    fi
    [[ -f $path && ! -L $path && $path != /usr/lib/debug/* ]] || continue
    [[ "$(head -c4 "$path" | od -An -c | tr -d ' ')" == '177ELF' ]] || continue
    # Bundled foreign-architecture code (box64's x86 libraries, firmware).
    [[ "$(readelf -h "$path" 2>/dev/null | sed -n 's/^ *Machine: *//p')" == "$machine" ]] || continue
    # Static binaries have no dynamic section to check. Captured whole:
    # `grep -q` on a pipe would SIGPIPE readelf and fail under pipefail.
    dyn=$(readelf -d "$path" 2>/dev/null || true)
    [[ $dyn == *"(NEEDED)"* ]] || continue

    needed=$(sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' <<<"$dyn" | rebuild_sonames)
    if [[ -n $needed ]]; then
      problem rule "$path" "links $(echo $needed), which needs rebuilds the fast ring cannot give it"
      continue
    fi

    prog=$(readelf -l "$path" 2>/dev/null || true)
    interp=$(sed -n 's/.*Requesting program interpreter: \(.*\)\]/\1/p' <<<"$prog")
    if [[ -n $interp && ! -e $interp ]]; then
      problem link "$path" "interpreter $interp not found"
      continue
    fi
    kind=$(elf_kind "$path" "$prog")

    out=$(ldd -r "$path" 2>&1 | ldd_problems "$kind")
    if [[ -n $out ]]; then
      dirs=()
      while IFS= read -r soname; do
        [[ -n ${shipped[$soname]:-} ]] || continue
        mapfile -t copies < <(printf '%s' "${shipped[$soname]}")
        dir=$(bundled_dir "$path" "${copies[@]}")
        [[ " ${dirs[*]} " == *" $dir "* ]] || dirs+=("$dir")
      # Its own NEEDED entries, and whatever its libraries could not find.
      done < <(sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' <<<"$dyn"
               sed -n 's/^[[:space:]]*\([^ ]*\) => not found.*/\1/p' <<<"$out")
      if (( ${#dirs[@]} )); then
        out=$(LD_LIBRARY_PATH=$(IFS=:; echo "${dirs[*]}") ldd -r "$path" 2>&1 | ldd_problems "$kind")
      fi
    fi
    if [[ -n $out ]]; then
      # Load addresses differ between runs; drop them so channels compare.
      mapfile -t lines < <(sed -E 's/^[[:space:]]+//; s/ \(0x[0-9a-f]+\)$//' <<<"$out")
      problem link "$path" "${lines[@]}"
    fi
  done
  return 0
}

# check <results> <package file>...
check() {
  local results=$1 file
  local -a names=()
  shift
  : > "$results"
  # Scriptlets would need a booted system; their output is not under test.
  if ! pacman -U --noconfirm --noscriptlet --ask 4 "$@"; then
    problem rule - "the channel cannot satisfy the packages' dependencies" > "$results"
    return 0
  fi
  for file in "$@"; do
    names+=("$(bsdtar -xOf "$file" .PKGINFO | sed -n 's/^pkgname = //p')")
  done
  # A metapackage installs no files; that is a pass.
  { pacman -Qlq "${names[@]}" | grep -v '/$' || true; } | inspect_files > "$results"
}

# channel_failures <edge results> <channel results>: the channel's problems
# that block the fast ring. Rule problems always do; link problems only
# when edge does not have the same one.
channel_failures() {
  # Marked by argument, not NR == FNR: an empty edge file would make that
  # hold for the channel's lines too, and every failure would vanish.
  awk -F'\t' 'file == "edge" { if ($1 == "link") edge[$0] = 1; next }
    $1 == "rule" || !($0 in edge)' file=edge "$1" file=channel "$2"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  command=${1:-}
  shift || true
  case "$command" in
    prepare) prepare "$@" ;;
    check) check "$@" ;;
    *) echo "usage: $0 prepare <channel> <arch> | check <results> <package file>..." >&2; exit 2 ;;
  esac
fi
