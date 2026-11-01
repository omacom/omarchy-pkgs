# Reading a package's .PKGINFO the way repo-add does, and only when it is
# what makepkg writes.
#
# repo-add (pacman 7.1, /usr/bin/repo-add:218-237) reads the .PKGINFO
# member with `bsdtar -xOqf` and splits each line with `IFS=' =' read -r var
# val`. pkginfo_fields reads it the same way, so what is checked before
# publishing is what repo-add records, and accepts only what makepkg writes:
#   - exactly one archive member named .PKGINFO, a regular file
#   - no control character but newline
#   - every key one makepkg writes, as a bare word
#   - no empty value for a key that repeats (license, depend, ...), and no
#     value that reads like a database field (%NAME%): repo-add's
#     format_entry writes a field's values one per line and ends the field
#     with a blank line. An empty single-valued key (makepkg writes
#     "pkgdesc = " for a recipe without one) is left out of the entry
#   - pkgname, pkgbase, pkgver and arch once each, in their own syntax

PKGINFO_KEYS="pkgname pkgbase pkgver pkgdesc url builddate packager size arch
  license group depend optdepend conflict provides replaces makedepend
  checkdepend backup xdata"
PKGINFO_ONCE="pkgname pkgbase pkgver pkgdesc url builddate packager size arch"

# pkginfo_fields <package file>: the .PKGINFO as "key TAB value" lines, in
# file order, or an error on stderr and status 1.
pkginfo_fields() {
  local f=$1 names line var val raw
  local -A count=()
  names=$(bsdtar -tf "$f" 2>/dev/null) || { echo "$f: not a readable package archive" >&2; return 1; }
  # bsdtar's .PKGINFO pattern also matches ./.PKGINFO and anything under a
  # .PKGINFO directory, so exactly one member may answer to it: the plain
  # file makepkg writes, spelled as makepkg spells it.
  if (( $(grep -cE '^(\./)*\.PKGINFO(/|$)' <<<"$names" || true) != 1 )) || ! grep -qx '\.PKGINFO' <<<"$names" \
    || [[ $(bsdtar -tvf "$f" .PKGINFO 2>/dev/null | cut -c1) != "-" ]]; then
    echo "$f: needs exactly one regular .PKGINFO member" >&2
    return 1
  fi
  raw=$(bsdtar -xOqf "$f" .PKGINFO | LC_ALL=C tr -d '\n' | LC_ALL=C tr -cd '\000-\037\177' | wc -c)
  (( raw == 0 )) || { echo "$f: .PKGINFO holds a control character" >&2; return 1; }
  while read -r line || [[ -n $line ]]; do
    [[ ${line:0:1} == "#" ]] && continue
    IFS=' =' read -r var val < <(printf '%s\n' "$line")
    [[ -n $var ]] || continue
    if [[ ! $var =~ ^[a-z]+$ || " $(echo $PKGINFO_KEYS) " != *" $var "* ]]; then
      echo "$f: .PKGINFO has a key makepkg does not write: $var" >&2
      return 1
    fi
    if [[ ( -z $val && " $(echo $PKGINFO_ONCE) " != *" $var "* ) || $val =~ ^%[A-Z0-9]+%$ ]]; then
      echo "$f: .PKGINFO has $var = '$val', which repo-add would write as a field boundary" >&2
      return 1
    fi
    count[$var]=$(( ${count[$var]:-0} + 1 ))
    printf '%s\t%s\n' "$var" "$val"
  done < <(bsdtar -xOqf "$f" .PKGINFO)
  for var in $PKGINFO_ONCE; do
    (( ${count[$var]:-0} <= 1 )) || { echo "$f: .PKGINFO has $var more than once" >&2; return 1; }
  done
  for var in pkgname pkgbase pkgver arch; do
    (( ${count[$var]:-0} == 1 )) || { echo "$f: .PKGINFO lacks $var" >&2; return 1; }
  done
}

# pkginfo_identity <package file>: "pkgname pkgbase pkgver arch" from a
# .PKGINFO pkginfo_fields accepts, each in its own syntax; or status 1.
pkginfo_identity() {
  local f=$1 fields name base ver arch
  fields=$(pkginfo_fields "$f") || return 1
  name=$(awk -F'\t' '$1 == "pkgname" {print $2}' <<<"$fields")
  base=$(awk -F'\t' '$1 == "pkgbase" {print $2}' <<<"$fields")
  ver=$(awk -F'\t' '$1 == "pkgver" {print $2}' <<<"$fields")
  arch=$(awk -F'\t' '$1 == "arch" {print $2}' <<<"$fields")
  # Names as makepkg allows them (it permits uppercase), a version as
  # [epoch:]pkgver-pkgrel, an architecture as a single word. ALPM allows
  # more in a pkgver (any ASCII but : / - < > = and space); Omarchy takes
  # only these, which every package it serves uses, and none of which
  # globs or quotes in a shell.
  if [[ ! $name =~ ^[a-zA-Z0-9@_+][a-zA-Z0-9@._+-]*$ || ! $base =~ ^[a-zA-Z0-9@_+][a-zA-Z0-9@._+-]*$ \
    || ! $ver =~ ^([0-9]+:)?[a-zA-Z0-9._+~]+-[0-9]+(\.[0-9]+)?$ || ! $arch =~ ^[a-z0-9_]+$ ]]; then
    echo "$f: .PKGINFO identity is not well formed: $name $base $ver $arch" >&2
    return 1
  fi
  echo "$name $base $ver $arch"
}
