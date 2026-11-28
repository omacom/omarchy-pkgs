#!/bin/bash
# One pkgname is built by one directory, per architecture. Two directories that
# build the same name publish the same filenames, and whichever artifact is
# collected last wins: #1878 built linux-omarchy as pkgbase linux-omarchy-bore,
# collided with the transitional package of that name, and edge kept the stub.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# Print "name/arch<TAB>dir" for every pkgname each directory builds, read the
# way the build planner reads a recipe: with CARCH set, in a subshell.
claim() {
  local root="$1" pkgdir
  for pkgdir in "$root"/*/; do
    (cd "$pkgdir" && env -u OMARCHY_SRC bash -c '
      source ./PKGBUILD >/dev/null 2>&1 || exit 0
      names=("${pkgname[@]}")
      (( ${#names[@]} )) || names=("${pkgbase:-}")
      for pkg in "${names[@]}"; do
        for a in "${arch[@]}"; do printf "%s/%s\t%s\n" "$pkg" "$a" "$(basename "$PWD")"; done
      done
    ' 2>/dev/null) || true
  done
}

# Name every name/arch that more than one directory builds.
collisions() {
  claim "$1" | sort -u | awk -F'\t' '
    $1 != key { if (count > 1) print key ": built by" dirs; key = $1; dirs = ""; count = 0 }
    { dirs = dirs " " $2; count++ }
    END { if (count > 1) print key ": built by" dirs }
  '
}

out=$(collisions "$ROOT/pkgbuilds")
[[ -z $out ]] && pass "each pkgname is built by one directory per architecture" \
  || fail "$out"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for dir in one two; do
  mkdir -p "$T/pkgbuilds/$dir"
  printf 'pkgname=(clash)\narch=(x86_64)\n' >"$T/pkgbuilds/$dir/PKGBUILD"
done
out=$(collisions "$T/pkgbuilds")
[[ $out == *"clash/x86_64: built by one two"* ]] && pass "a name built twice is refused" \
  || fail "the duplicate was not reported: ${out:-nothing}"
