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
#   rule  fails wherever it happens: packages that cannot be installed, a
#         file under /usr/lib/python3.X, and, when COMPILED=1 says this
#         repository compiles the package, an ELF linking Qt or libpython.
#         Those break on a dependency update without a missing symbol to
#         show it (Qt's private API and plugin version check, Python's
#         versioned module path), so they need rebuilds the fast ring
#         cannot give them.
#   link  a dependency the channel cannot provide, or an ELF whose
#         libraries, symbol versions or interpreter are missing (`ldd -r`). Fails only where edge does not show the same
#         line: an optional plugin whose library nobody installs is no
#         different on stable.
# The rebuild_on half of the rule is metadata, enforced by
# validate_package_metadata.
#
# A promotion copies an edge build into rc or stable in the same way, so
# promote.yml runs this check too, through bin/check-promotion:
#
#   fast-ring-check.sh prepare-view <channel> <from> <arch> <name>...
#   fast-ring-check.sh check-plan <results> <name>=<file>...
#
# `prepare-view` makes the channel look as the promotion would leave it: the
# named packages' entries move from its [omarchy] repository to a [promoted]
# one with <from>'s entries. `check-plan` downloads files from it and runs
# `check`. A problem the source and edge both show is then the baseline.
# With PROMOTION=1 a promoted package is not held to the fast ring's rule
# on Python modules: it is a link problem only when the channel lacks the
# Python version the module was built for, and its extension modules get
# the ELF check like any other file.

set -euo pipefail

# Where each channel's Arch packages come from, as in build/Dockerfile:
# Omarchy's mirrors of Arch for x86_64 and of Arch Linux ARM for aarch64, a
# snapshot each for rc and stable.
channel_mirror() { # channel_mirror <channel> <arch>
  case "$2:$1" in
    x86_64:stable) echo 'https://stable-mirror.omarchy.org/$repo/os/$arch' ;;
    x86_64:rc) echo 'https://rc-mirror.omarchy.org/$repo/os/$arch' ;;
    x86_64:edge) echo 'https://mirror.omarchy.org/$repo/os/$arch' ;;
    aarch64:stable) echo 'https://arm-stable-mirror.omarchy.org/$arch/$repo' ;;
    aarch64:rc) echo 'https://arm-rc-mirror.omarchy.org/$arch/$repo' ;;
    aarch64:edge) echo 'https://arm-mirror.omarchy.org/$arch/$repo' ;;
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
  local channel=$1 arch=$2 mode=${3:-} server
  local base=${OMARCHY_PKGS_BASE:-https://pkgs.omarchy.org}
  local conf=${PACMAN_CONF:-/etc/pacman.conf}
  local -a foreign=()
  server=$(channel_mirror "$channel" "$arch") || { echo "unknown channel $channel for $arch" >&2; exit 2; }
  printf 'Server = %s\n' "$server" > /etc/pacman.d/mirrorlist
  sed -i '/^\[omarchy\]/,/^$/d' "$conf"
  if [[ $mode != --no-omarchy ]]; then
    sed -i "/^\[core\]$/i [omarchy]\nSigLevel = Required DatabaseOptional\nServer = $base/$channel/$arch\n" "$conf"
  fi
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

# split_db <channel db> <from db> <promoted db> <name>...: the channel as a
# promotion of the named packages would leave it, in two databases. The
# named packages' entries leave <channel db>, and <promoted db> holds their
# entries from <from db>, so no dependency can resolve to a version the
# promotion replaces.
split_db() {
  local channel=$1 from=$2 promoted=$3 t name dir
  shift 3
  local -A in_channel=() in_from=()
  t=$(mktemp -d)
  mkdir "$t/channel" "$t/from" "$t/promoted"
  if ! bsdtar -xf "$channel" -C "$t/channel" || ! bsdtar -xf "$from" -C "$t/from"; then
    rm -rf "$t"
    return 1
  fi
  for dir in "$t/channel"/*/; do
    [[ -d $dir ]] || continue
    in_channel[$(sed -n '/^%NAME%$/{n;p;q}' "$dir/desc")]=$dir
  done
  for dir in "$t/from"/*/; do
    [[ -d $dir ]] || continue
    in_from[$(sed -n '/^%NAME%$/{n;p;q}' "$dir/desc")]=$dir
  done
  for name in "$@"; do
    [[ -n ${in_from[$name]:-} ]] || { echo "$name is not in the source database" >&2; rm -rf "$t"; return 1; }
    cp -R "${in_from[$name]}" "$t/promoted/" || { rm -rf "$t"; return 1; }
    if [[ -n ${in_channel[$name]:-} ]]; then
      rm -rf "${in_channel[$name]}" || { rm -rf "$t"; return 1; }
    fi
  done
  # Entries at the top level, as repo-add writes them: no ./ prefix. An
  # empty database is a valid one.
  if ! (cd "$t/promoted" && bsdtar -czf "$promoted" -- *) ||
    ! (cd "$t/channel" && shopt -s nullglob && entries=(*) && bsdtar -czf "$channel" -T /dev/null -- "${entries[@]}"); then
    rm -rf "$t"
    return 1
  fi
  rm -rf "$t"
}

# prepare_view <channel> <from> <arch> <name>...: prepare <channel>, then
# make it look as a promotion of the named packages from <from> would
# leave it: their entries move from its [omarchy] repository to a
# [promoted] one served from <from>. One server per repository: libalpm
# stops asking a host after a few failed downloads, so a fallback Server on
# the same host is no use. A destination before its first promotion has no
# [omarchy] database yet (HTTP 404) and gets an empty view without [omarchy].
prepare_view() {
  local channel=$1 from=$2 arch=$3 code rc t
  local base=${OMARCHY_PKGS_BASE:-https://pkgs.omarchy.org}
  local conf=${PACMAN_CONF:-/etc/pacman.conf}
  local sync=${PACMAN_SYNC:-/var/lib/pacman/sync}
  shift 3
  t=$(mktemp -d)
  # The CDN can serve a database a minute old; a query string skips it.
  rc=0
  code=$(curl -sSL --retry 3 -o "$t/channel.db" -w '%{http_code}' "$base/$channel/$arch/omarchy.db?$RANDOM") || rc=$?
  if (( rc == 0 )) && [[ $code == 200 ]]; then
    prepare "$channel" "$arch" || { rm -rf "$t"; return 1; }
    mv "$t/channel.db" "$sync/omarchy.db"
  elif (( rc == 0 )) && [[ $code == 404 && $channel != "$from" && $channel != edge ]]; then
    prepare "$channel" "$arch" --no-omarchy || { rm -rf "$t"; return 1; }
    bsdtar -czf "$sync/omarchy.db" -T /dev/null
  else
    rm -rf "$t"
    echo "cannot fetch $base/$channel/$arch/omarchy.db (curl exit $rc, HTTP ${code:-000})" >&2
    return 1
  fi
  if ! curl -fsSL --retry 3 -o "$t/from.db" "$base/$from/$arch/omarchy.db?$RANDOM"; then
    rm -rf "$t"
    return 1
  fi
  if ! split_db "$sync/omarchy.db" "$t/from.db" "$sync/promoted.db" "$@"; then
    rm -rf "$t"
    return 1
  fi
  rm -rf "$t"
  rm -f "$sync/omarchy.db.sig"
  if grep -q '^\[omarchy\]$' "$conf"; then
    sed -i "/^\[omarchy\]$/i [promoted]\nSigLevel = Required DatabaseOptional\nServer = $base/$from/$arch\n" "$conf"
  else
    rm -f "$sync/omarchy.db"
    sed -i "/^\[core\]$/i [promoted]\nSigLevel = Required DatabaseOptional\nServer = $base/$from/$arch\n" "$conf"
  fi
}

# check_plan <results> <name>=<file>...: download the files from the
# [promoted] repository prepare_view left and check them.
check_plan() {
  local results=$1 arg
  local -a names=() files=()
  shift
  local served
  for arg in "$@"; do
    names+=("promoted/${arg%%=*}")
    files+=("/var/cache/pacman/pkg/${arg#*=}")
    # The source moved since the plan was made: check what was planned or
    # nothing.
    served=$(pacman -Sddp --print-format '%f' "promoted/${arg%%=*}" 2>/dev/null || true)
    if [[ $served != "${arg#*=}" ]]; then
      problem rule - "the source serves ${served:-nothing} for ${arg%%=*}, not the planned ${arg#*=}" > "$results"
      return 0
    fi
  done
  if ! pacman -Sddw --noconfirm "${names[@]}" >&2; then
    problem rule - "the packages cannot be downloaded from the promotion's source" > "$results"
    return 0
  fi
  check "$results" "${files[@]}"
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
  local -A shipped=() python=()
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
    if [[ $path =~ ^/usr/lib/python(3\.[0-9]+)/ ]]; then
      if [[ ${PROMOTION:-} != 1 ]]; then
        problem rule "$path" "a Python module, which breaks when Python's minor version moves"
        continue
      fi
      # Once per version: a module tree has thousands of files.
      if [[ ! -x /usr/bin/python${BASH_REMATCH[1]} && -z ${python[${BASH_REMATCH[1]}]:-} ]]; then
        python[${BASH_REMATCH[1]}]=1
        problem link "/usr/lib/python${BASH_REMATCH[1]}" "Python ${BASH_REMATCH[1]} modules, and this channel has no Python ${BASH_REMATCH[1]}"
      fi
    fi
    [[ -f $path && ! -L $path && $path != /usr/lib/debug/* ]] || continue
    [[ "$(head -c4 "$path" | od -An -c | tr -d ' ')" == '177ELF' ]] || continue
    # Bundled foreign-architecture code (box64's x86 libraries, firmware).
    [[ "$(readelf -h "$path" 2>/dev/null | sed -n 's/^ *Machine: *//p')" == "$machine" ]] || continue
    # Static binaries have no dynamic section to check. Captured whole:
    # `grep -q` on a pipe would SIGPIPE readelf and fail under pipefail.
    dyn=$(readelf -d "$path" 2>/dev/null || true)
    [[ $dyn == *"(NEEDED)"* ]] || continue

    # Only for code compiled here: a vendor's binary is the same bytes
    # whatever we rebuild, so the link check below is all that applies.
    needed=""
    [[ ${COMPILED:-} == 1 ]] && needed=$(sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' <<<"$dyn" | rebuild_sonames)
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

    # ldd exits non-zero on what glibc cannot load at all (the musl and
    # Android prebuilds Electron apps carry beside the glibc one); what it
    # prints is still the answer.
    out=$(ldd -r "$path" 2>&1 | ldd_problems "$kind" || true)
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
        out=$(LD_LIBRARY_PATH=$(IFS=:; echo "${dirs[*]}") ldd -r "$path" 2>&1 | ldd_problems "$kind" || true)
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

# install_resolvable_dependencies <pacman log> <package file>...: the
# packages' dependencies, minus the ones the log says cannot be resolved and
# the ones the packages provide each other.
install_resolvable_dependencies() {
  local log=$1 file dep
  shift
  local -a wanted=()
  local -A skip=()
  while IFS= read -r dep; do
    skip[$dep]=1
  done < <(sed -n 's/.*warning: cannot resolve "\([^"]*\)", a dependency of .*/\1/p' <<<"$log")
  for file in "$@"; do
    while IFS= read -r dep; do
      skip[$dep]=1
    done < <(bsdtar -xOf "$file" .PKGINFO | sed -n 's/^\(pkgname\|provides\) = \([^=<>]*\).*/\2/p')
  done
  for file in "$@"; do
    while IFS= read -r dep; do
      [[ -n ${skip[$dep]:-} || -n ${skip[${dep%%[<>=]*}]:-} ]] || wanted+=("$dep")
    done < <(bsdtar -xOf "$file" .PKGINFO | sed -n 's/^depend = //p')
  done
  (( ${#wanted[@]} )) || return 0
  pacman -S --needed --asdeps --noconfirm --noscriptlet --ask 4 "${wanted[@]}"
}

# check <results> <package file>...
check() {
  local results=$1 file
  local -a names=() lines=()
  shift
  : > "$results"
  local log deps
  # Scriptlets would need a booted system; their output is not under test.
  if ! log=$(pacman -U --noconfirm --noscriptlet --ask 4 "$@" 2>&1); then
    # To stderr: bin/check-fast-ring discards the transaction's stdout.
    printf '%s\n' "$log" >&2
    # A dependency is compared with edge like a library: one no channel
    # carries (an AUR-only theme engine, say) is not the fast ring's to
    # judge. The files are still inspected, installed without it.
    deps=$(sed -n 's/.*warning: cannot resolve "\([^"]*\)", a dependency of "\([^"]*\)"$/\2 needs \1, which this channel cannot provide/p' <<<"$log")
    if [[ -z $deps ]]; then
      problem rule - "the packages cannot be installed on this channel" > "$results"
      return 0
    fi
    mapfile -t lines <<<"$deps"
    problem link - "${lines[@]}" > "$results"
    # Everything else they depend on is installed first, from this channel,
    # so its libraries are the ones inspected and not missing everywhere.
    if ! install_resolvable_dependencies "$log" "$@"; then
      problem rule - "the packages' other dependencies cannot be installed on this channel" > "$results"
      return 0
    fi
    pacman -Udd --noconfirm --noscriptlet --ask 4 "$@"
  fi
  local name version installed
  for file in "$@"; do
    name=$(bsdtar -xOf "$file" .PKGINFO | sed -n 's/^pkgname = //p')
    version=$(bsdtar -xOf "$file" .PKGINFO | sed -n 's/^pkgver = //p')
    # pacman can drop a target that conflicts with another one providing
    # its name, and -Qlq would then list the provider's files.
    installed=$(pacman -Q "$name" 2>&1 || true)
    if [[ $installed != "$name $version" ]]; then
      problem rule - "$name $version was not installed ($installed)" >> "$results"
      return 0
    fi
    names+=("$name")
  done
  local list
  if ! list=$(pacman -Qlq "${names[@]}"); then
    problem rule - "pacman could not list the installed files" >> "$results"
    return 0
  fi
  # A metapackage installs no files; that is a pass.
  { grep -v '/$' <<<"$list" || true; } | inspect_files >> "$results"
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
    prepare-view) prepare_view "$@" ;;
    check-plan) check_plan "$@" ;;
    *) echo "usage: $0 prepare <channel> <arch> | check <results> <package file>... | prepare-view <channel> <from> <arch> <name>... | check-plan <results> <name>=<file>..." >&2; exit 2 ;;
  esac
fi
