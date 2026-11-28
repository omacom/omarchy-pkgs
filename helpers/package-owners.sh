# Owner check for built packages
#
# pacman installs every file with the numeric owner its package records and
# looks up no names. makepkg records whatever package() left under fakeroot,
# so a vendor archive extracted there keeps the IDs of the machine that made
# it. A file owned by uid 1001 then belongs to the second account on the
# user's machine, and that account can replace it.
#
# So every file must be owned by root, in root's group or in a group that
# Arch's own packages use with a fixed ID: tty (5), ftp (11) or games (50).

PACKAGE_OWNER_GIDS="0 5 11 50"

# check_package_owners <package file>...
# Prints the entries of each file that break the rule, and returns 1 if any
# file has one or cannot be read.
check_package_owners() {
  local file bad status=0

  for file in "$@"; do
    if ! bad=$(set -o pipefail; bsdtar -tvf "$file" --numeric-owner |
      awk -v gids="$PACKAGE_OWNER_GIDS" '
        BEGIN { n = split(gids, list, " "); for (i = 1; i <= n; i++) allowed[list[i]] = 1 }
        $3 != 0 || !($4 in allowed)'); then
      echo "    Cannot list the files of ${file##*/}"
      status=1
    elif [[ -n $bad ]]; then
      echo "    ${file##*/} has $(wc -l <<<"$bad") files that pacman would install with a non-root owner:"
      sed -n '1,5s/^/      /p' <<<"$bad"
      echo "    Extract vendor archives in package() with bsdtar --no-same-owner."
      status=1
    fi
  done

  return $status
}
