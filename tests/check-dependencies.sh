#!/bin/bash
# Self-test for bin/check-dependencies on small repository databases built
# here, with the cases of 2026-10-28. Needs bsdtar and vercmp (Arch).
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
check=$ROOT/bin/check-dependencies
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# db <file> <name>:<version>:<depends,...>:<provides,...>...: a repository
# database holding those packages.
db() {
  local file=$work/$1 entry name version deps provs dir
  shift
  dir=$(mktemp -d)
  for entry in "$@"; do
    IFS=: read -r name version deps provs <<<"$entry"
    mkdir -p "$dir/$name-$version"
    {
      printf '%%NAME%%\n%s\n\n%%VERSION%%\n%s\n\n' "$name" "$version"
      if [[ -n $deps ]]; then printf '%%DEPENDS%%\n%s\n\n' "${deps//,/$'\n'}"; fi
      if [[ -n $provs ]]; then printf '%%PROVIDES%%\n%s\n\n' "${provs//,/$'\n'}"; fi
    } > "$dir/$name-$version/desc"
  done
  bsdtar -czf "$file" -C "$dir" .
  rm -rf "$dir"
  echo "$file"
}

core=$(db core.db glibc:2.44-1::)

# Edge on 2026-10-28: extra moved hyprland to 0.57.0.
ours=$(db o1.db omarchy-hyprland-titlebars:0.2.2-2:glibc,hyprland=0.56.2:)
extra=$(db e1.db hyprland:0.57.0-1:glibc:)
[[ $("$check" "$ours" "$core" "$extra") == $'omarchy-hyprland-titlebars\thyprland=0.56.2' ]] ||
  fail "a pin the repositories no longer meet is reported"
pass "a pin the repositories no longer meet is reported"

# The first repository with a name wins, even when a later one still has a
# version that meets the pin: an upgrade takes [omarchy]'s 0.57.0.
ours=$(db o2.db omarchy-hyprland-titlebars:0.2.2-2:hyprland=0.56.2: hyprland:0.57.0-1::)
extra=$(db e2.db hyprland:0.56.2-4::)
[[ $("$check" "$ours" "$core" "$extra") == $'omarchy-hyprland-titlebars\thyprland=0.56.2' ]] ||
  fail "the first repository's copy is the one that counts"
pass "the first repository's copy is the one that counts"

# #1802: Omarchy's 0.56.2-8 meets a pin without a release.
ours=$(db o3.db omarchy-hyprland-titlebars:0.2.2-2:hyprland=0.56.2: hyprland:0.56.2-8::)
extra=$(db e3.db hyprland:0.57.0-1::)
[[ -z $("$check" "$ours" "$core" "$extra") ]] || fail "a pin without a release accepts any release"
pass "a pin without a release accepts any release"

# cua-hyprland-plugin pins the release too.
ours=$(db o4.db cua-hyprland-plugin:0.33.2-4:hyprland=0.56.2-4: hyprland:0.56.2-8::)
[[ $("$check" "$ours" "$core" "$extra") == $'cua-hyprland-plugin\thyprland=0.56.2-4' ]] ||
  fail "a pin with a release needs that release"
pass "a pin with a release needs that release"

# Provisions: a versioned one meets a soname dependency, an unversioned one
# does not, as in pacman.
ours=$(db o5.db plugin:1-1:libhyprutils.so=13:)
extra=$(db e5.db hyprutils:0.14.3-1::libhyprutils.so=13-64)
[[ -z $("$check" "$ours" "$core" "$extra") ]] || fail "a versioned provision meets a soname dependency"
extra=$(db e6.db hyprutils:0.14.3-1::libhyprutils.so)
[[ $("$check" "$ours" "$core" "$extra") == $'plugin\tlibhyprutils.so=13' ]] ||
  fail "an unversioned provision does not meet a versioned dependency"
pass "provisions meet dependencies as in pacman"

# Arch's own packages are checked too: what ours pull in has to install, and
# an Arch package that depends on something we override breaks with it.
ours=$(db o7.db omarchy-shell:1-1:quickshell:)
extra=$(db e7.db quickshell:0.3.2-1:qt6-base=6.11.2: qt6-base:6.12.0-1::)
[[ $("$check" "$ours" "$core" "$extra") == $'quickshell\tqt6-base=6.11.2' ]] ||
  fail "Arch packages ours pull in are checked"
ours=$(db o8.db libfoo:2-1::)
extra=$(db e8.db consumer:1-1:libfoo=1: libfoo:1-1::)
[[ $("$check" "$ours" "$core" "$extra") == $'consumer\tlibfoo=1' ]] ||
  fail "an Arch package that depends on what we override is checked"
pass "Arch packages are checked against what we override"

# An unversioned replaces takes the replaced package away; a versioned one
# only replaces versions the repositories no longer have.
ours=$(db o10.db successor:2-1::)
extra=$(db e10.db app:1-1:legacy: legacy:1-1::)
dir=$(mktemp -d); mkdir -p "$dir/successor-2-1"
printf '%s\n' '%NAME%' 'successor' '' '%VERSION%' '2-1' '' '%REPLACES%' 'legacy' '' > "$dir/successor-2-1/desc"
bsdtar -czf "$work/o10.db" -C "$dir" .
[[ $("$check" "$ours" "$core" "$extra") == $'app\tlegacy' ]] || fail "an unversioned replaces removes the replaced package"
printf '%s\n' '%NAME%' 'successor' '' '%VERSION%' '2-1' '' '%REPLACES%' 'legacy<1' '' > "$dir/successor-2-1/desc"
bsdtar -czf "$work/o10.db" -C "$dir" .
[[ -z $("$check" "$ours" "$core" "$extra") ]] || fail "a versioned replaces leaves current versions alone"
rm -rf "$dir"
pass "replaces removes packages as an upgrade does"

# raw_db <file> <name> <version> <field> <value>...: one package with
# arbitrary fields, for replaces and provides together.
raw_db() {
  local file=$work/$1 name=$2 version=$3 dir
  shift 3
  dir=$(mktemp -d); mkdir -p "$dir/$name-$version"
  {
    printf '%s\n' '%NAME%' "$name" '' '%VERSION%' "$version" ''
    while (( $# )); do printf '%s\n' "%$1%" "$2" ''; shift 2; done
  } > "$dir/$name-$version/desc"
  bsdtar -czf "$file" -C "$dir" .
  rm -rf "$dir"
  echo "$file"
}

# A replaced package that provides something is still gone.
ours=$(raw_db o11.db successor 2-1 REPLACES legacy)
extra=$(raw_db e11.db app 1-1 DEPENDS legacy)
legacy=$(raw_db l11.db legacy 1-1 PROVIDES legacy-api)
[[ $("$check" "$ours" "$core" "$extra" "$legacy") == $'app\tlegacy' ]] ||
  fail "a replaced package with provisions is still gone"
pass "a replaced package with provisions is still gone"

# A versioned replaces counts when the replaced version matches it.
ours=$(raw_db o12.db successor 2-1 REPLACES 'legacy<2')
[[ $("$check" "$ours" "$core" "$extra" "$legacy") == $'app\tlegacy' ]] ||
  fail "a versioned replaces that matches removes the package"
pass "a versioned replaces that matches removes the package"

# A replacement from a later repository does not touch an earlier one's
# package: pacman takes the first repository's copy and stops.
ours=$(raw_db o13.db legacy 1-1)
later=$(raw_db x13.db successor 2-1 REPLACES legacy)
[[ -z $("$check" "$ours" "$core" "$extra" "$later") ]] ||
  fail "a later repository's replaces leaves an earlier package alone"
pass "a later repository's replaces leaves an earlier package alone"

# Arch Linux ARM writes the older layout: %DEPENDS% and %PROVIDES% in a
# separate depends file next to desc.
dir=$(mktemp -d); mkdir -p "$dir/libglvnd-1.7.0-3" "$dir/hyprland-0.57.0-2"
printf '%s\n' '%NAME%' 'libglvnd' '' '%VERSION%' '1.7.0-3' '' > "$dir/libglvnd-1.7.0-3/desc"
printf '%s\n' '%PROVIDES%' 'libEGL.so=1-64' '' > "$dir/libglvnd-1.7.0-3/depends"
printf '%s\n' '%NAME%' 'hyprland' '' '%VERSION%' '0.57.0-2' '' > "$dir/hyprland-0.57.0-2/desc"
printf '%s\n' '%DEPENDS%' 'libEGL.so=1-64' 'libgone.so=2-64' '' > "$dir/hyprland-0.57.0-2/depends"
bsdtar -czf "$work/alarm.db" -C "$dir" .
rm -rf "$dir"
ours=$(db o14.db)
[[ $("$check" "$ours" "$core" "$work/alarm.db") == $'hyprland\tlibgone.so=2-64' ]] ||
  fail "the older layout with a separate depends file is read"
pass "the older layout with a separate depends file is read"

# A missing dependency is reported.
ours=$(db o9.db yaru-gtk-theme:1-1:gtk-engine-murrine:)
extra=$(db e9.db hyprland:0.56.2-4::)
[[ $("$check" "$ours" "$core" "$extra") == $'yaru-gtk-theme\tgtk-engine-murrine' ]] ||
  fail "a dependency no repository has is reported"
pass "a dependency no repository has is reported"
