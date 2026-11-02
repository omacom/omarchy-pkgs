#!/bin/bash
# Self-test for helpers/repo-db.sh against databases repo-add writes: a
# value line that reads like a field is a value, and an entry that names a
# field twice is refused, not read either way.
# Needs repo-add and bsdtar (run in the Arch test container).
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
source "$ROOT/helpers/repo-db.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# db <name> <pkgname> <license values...>: a database holding one package
# whose .PKGINFO carries those license lines, as repo-add writes it.
db() {
  local d="$T/$1" v; mkdir -p "$d/pkg/usr/share"
  {
    printf 'pkgname = %s\npkgbase = %s\npkgver = 1.0-1\narch = any\nsize = 0\n' "$2" "$2"
    for v in "${@:3}"; do printf 'license = %s\n' "$v"; done
  } > "$d/pkg/.PKGINFO"
  ( cd "$d/pkg" && bsdtar --zstd -cf "$d/$2-1.0-1-any.pkg.tar.zst" .PKGINFO usr )
  ( cd "$d" && repo-add --quiet omarchy.db.tar.zst "$2-1.0-1-any.pkg.tar.zst" >/dev/null 2>&1 )
  echo "$d/omarchy.db.tar.zst"
}

got=$(repo_db_entries "$(db plain beta MIT '%NAME%' alpha '%VERSION%' 99-1)" | cut -f1-3)
[[ $got == $'beta\t1.0-1\tbeta' ]] && pass "license lines reading %NAME% and %VERSION% are values, not fields" || fail "plain: $got"

# Empty values end the field in the desc file, so what follows them reads
# as fields of its own.
twice=$(db twice beta MIT '' '%NAME%' alpha '' '%VERSION%' 99-1)
grep -qx '%NAME%' <(bsdtar -xOf "$twice" --include '*/desc') || fail "fixture: repo-add wrote no second field"
if got=$(repo_db_entries "$twice" 2>"$T/err"); then fail "a second %NAME% should be refused, read: $got"; fi
grep -q '%NAME% twice' "$T/err" && pass "an entry naming itself twice is refused" || fail "reason: $(cat "$T/err")"

# Several values join with spaces, and an unpacked database reads the same.
plain=$(db fields beta MIT GPL)
mkdir -p "$T/unpacked" && bsdtar -xf "$plain" -C "$T/unpacked"
[[ $(repo_db_fields "$plain" NAME LICENSE) == $'beta\tMIT GPL' && $(repo_db_fields "$T/unpacked" NAME LICENSE) == $'beta\tMIT GPL' ]] \
  && pass "a field's values join with spaces, from a database or its unpacked entries" || fail "fields: $(repo_db_fields "$plain" NAME LICENSE)"

# Entries repo-add never writes are refused, not read either way.
hand() { # hand <name> <desc text>: an unpacked database of one entry
  mkdir -p "$T/hand-$1/x-1" && printf '%b' "$2" > "$T/hand-$1/x-1/desc" && echo "$T/hand-$1"
}
for c in "tab:%NAME%\nx\tforged\n\n%VERSION%\n1-1\n" "second:%NAME%\nx\n\n%VERSION%\n9-1\n1-1\n" "noname:%VERSION%\n1-1\n"; do
  if got=$(repo_db_fields "$(hand "${c%%:*}" "${c#*:}")" NAME VERSION 2>/dev/null); then fail "${c%%:*}: read as $got"; fi
done
pass "a TAB in a value, a second VERSION or an entry without NAME is refused"
