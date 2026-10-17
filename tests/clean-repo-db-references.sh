#!/bin/bash
# #878: clean-repo trimmed old versions by age alone, so an archive the repository database still
# advertised could be deleted and every client's download of it would fail. The database decides what
# may go, and a database that cannot be read stops the cleanup instead of deleting on a guess.
set -euo pipefail

BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state" "$TEST_ROOT/repo/edge/x86_64"
cp "$BUILD_ROOT/bin/clean-repo" "$TEST_ROOT/bin/"
cp -r "$BUILD_ROOT/helpers" "$TEST_ROOT/"

REPO="$TEST_ROOT/repo/edge/x86_64"
archive() {  # $1 = archive name, $2 = mtime date
  : >"$REPO/$1"; : >"$REPO/$1.sig"
  touch -d "$2" "$REPO/$1" "$REPO/$1.sig"
}

# Two versions of one package: the trim keeps the newest, and the database will name the OLDER one,
# which is the version a client resolves and downloads. Distinct mtimes, because the trim sorts by
# them and files written in the same second have no order.
archive demo-1.0-1-x86_64.pkg.tar.zst '2026-01-01 00:00:00'
archive demo-2.0-1-x86_64.pkg.tar.zst '2026-06-01 00:00:00'
archive other-1.0-1-x86_64.pkg.tar.zst '2026-06-01 00:00:00'

write_database() {  # $1 = build dir, $2 = pkgname, $3 = pkgver-pkgrel
  mkdir -p "$1/$2-$3"
  printf '%%FILENAME%%\n%s-%s-x86_64.pkg.tar.zst\n\n%%NAME%%\n%s\n\n%%VERSION%%\n%s\n' \
    "$2" "$3" "$2" "$3" >"$1/$2-$3/desc"
}

run_clean() {  # $1 = repo root
  OMARCHY_REPO_ROOT="$1" OMARCHY_STATE_DIR="$TEST_ROOT/state" \
    bash "$TEST_ROOT/bin/clean-repo" --keep 1
}

mkdir -p "$TEST_ROOT/db"
write_database "$TEST_ROOT/db" demo "1.0-1"
(cd "$TEST_ROOT/db" && bsdtar -czf "$REPO/omarchy.db.tar.zst" .)
ln -sf omarchy.db.tar.zst "$REPO/omarchy.db"

run_clean "$TEST_ROOT/repo" >"$TEST_ROOT/out" 2>&1 || true
[[ -f "$REPO/demo-1.0-1-x86_64.pkg.tar.zst" ]] ||
  fail "an archive the database still names survives the trim" "$(cat "$TEST_ROOT/out")"
[[ -f "$REPO/demo-1.0-1-x86_64.pkg.tar.zst.sig" ]] ||
  fail "its signature survives with it" "$(cat "$TEST_ROOT/out")"
[[ -f "$REPO/demo-2.0-1-x86_64.pkg.tar.zst" ]] ||
  fail "the newest version is kept" "$(cat "$TEST_ROOT/out")"
[[ -f "$REPO/other-1.0-1-x86_64.pkg.tar.zst" ]] ||
  fail "a single-version package is kept" "$(cat "$TEST_ROOT/out")"
grep -q 'the database still points at it' "$TEST_ROOT/out" ||
  fail "the kept archive is reported" "$(cat "$TEST_ROOT/out")"

# Without a readable database nothing may be deleted: the script cannot know what is in use.
mkdir -p "$TEST_ROOT/repo2/edge/x86_64"
cp "$REPO"/*.pkg.tar.zst "$TEST_ROOT/repo2/edge/x86_64/"
if run_clean "$TEST_ROOT/repo2" >"$TEST_ROOT/out2" 2>&1; then
  fail "a repository without a readable database refuses to clean" "$(cat "$TEST_ROOT/out2")"
fi
[[ $(find "$TEST_ROOT/repo2/edge/x86_64" -maxdepth 1 -name '*.pkg.tar.zst' | wc -l) == 3 ]] ||
  fail "nothing is removed when the database cannot be read" "$(ls -1 "$TEST_ROOT/repo2/edge/x86_64")"

printf 'PASS: clean-repo keeps the archives the database names and stops without one\n'
