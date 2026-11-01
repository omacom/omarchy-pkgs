# Reading a channel database (omarchy.db.tar.zst) as data.
#
# Each package's entry is a desc file of fields, each a %KEY% line, its
# value lines, and a blank line. A field like %LICENSE% or %GROUPS% holds
# one value per line, copied from the package's own .PKGINFO, so a value
# line can read "%NAME%": only a %KEY% line that starts a field is a key.
# An entry repo-add would not write (a field named twice, a second value in
# a single-valued field, a TAB in a value, no %NAME%) is malformed, and the
# whole database is refused rather than read either way.

# repo_db_fields <db|dir> <KEY...>: one line per entry, the named fields'
# values TAB-separated in the order asked, a field's several values joined
# by spaces, a missing field empty. <dir> is a database already unpacked
# (<dir>/<name-version>/desc). An error on stderr and status 1 otherwise.
repo_db_fields() {
  local src=$1 dir status=0
  shift
  if [[ -d $src ]]; then
    dir=$src
  else
    dir=$(mktemp -d)
    bsdtar -xf "$src" -C "$dir" --include '*/desc' || status=1
  fi
  # A new desc file starts a new entry.
  (( status )) || find "$dir" -name desc -print0 | xargs -0r awk -v keys="$*" '
    BEGIN {
      n = split(keys, want, " ")
      split("FILENAME NAME BASE VERSION DESC CSIZE ISIZE MD5SUM SHA256SUM PGPSIG URL ARCH BUILDDATE PACKAGER", s, " ")
      for (i in s) single["%" s[i] "%"] = 1
    }
    function die(msg) { print entry ": " msg > "/dev/stderr"; bad = 1; exit 1 }
    function flush(   i, line) {
      if (entry != "") {
        if (!("%NAME%" in val)) die("no %NAME%")
        line = ""
        for (i = 1; i <= n; i++) line = line (i > 1 ? "\t" : "") val["%" want[i] "%"]
        print line
      }
      delete val; delete seen; key = ""
    }
    FNR == 1 { flush(); entry = FILENAME }
    key == "" {
      if ($0 ~ /^%[A-Z0-9]+%$/) { key = $0; if (seen[key]++) die(key " twice in one entry") }
      next
    }
    $0 == "" { key = ""; next }
    /\t/ { die(key " holds a tab") }
    {
      if ((key in val) && (key in single)) die(key " has more than one value")
      val[key] = (key in val ? val[key] " " : "") $0
    }
    END { if (!bad) flush() }' || status=1
  [[ -d $src ]] || rm -rf "$dir"
  return "$status"
}

# repo_db_entries <db|dir>: one line per package in the database,
#   name TAB version TAB base TAB filename TAB sha256 TAB csize
repo_db_entries() {
  repo_db_fields "$1" NAME VERSION BASE FILENAME SHA256SUM CSIZE
}
