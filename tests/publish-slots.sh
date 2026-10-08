#!/bin/bash
# A package is published only when every slot it ships to holds it, and a
# slot that lacks it gets the bytes another slot already publishes.
set -euo pipefail
BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
TEST_ROOT=$(mktemp -d)
trap 'kill "${server:-}" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/pkgbuilds" "$TEST_ROOT/www"
cp "$BUILD_ROOT"/bin/{build,publish-slots,fetch-published} "$TEST_ROOT/bin/"
cp -r "$BUILD_ROOT/helpers" "$BUILD_ROOT/build" "$TEST_ROOT/"
unset OMARCHY_REPO_ROOT OMARCHY_RC_PINS OMARCHY_DEFER_RUNTIME_DEPS

# recipe <dir> <pkgbase> <metadata json>: an arch=any recipe at 2-1 building
# <dir> and <pkgbase>-extra. Like yaru-icon-theme (pkgbase yaru), the
# directory is always one of the packages built: that name is how the build
# planner finds the recipe's version in a database.
recipe() {
  mkdir -p "$TEST_ROOT/pkgbuilds/$1/.omarchy"
  printf '%s\n' "$3" > "$TEST_ROOT/pkgbuilds/$1/.omarchy/package.json"
  printf 'pkgbase=%s\npkgname=(%s %s-extra)\npkgver=2\npkgrel=1\narch=(any)\n' "$2" "$1" "$2" > "$TEST_ROOT/pkgbuilds/$1/PKGBUILD"
}
recipe split-any split-any '{"source":"local","channels":["edge"]}'
recipe renamed-dir renamed '{"source":"local","channels":["edge"]}'
recipe fast-any fast-any '{"source":"local","release_ring":"fast"}'
recipe everywhere everywhere '{"source":"local","channels":["edge"]}'

# publish <mirror> <arch> <pkgbase> <version>...: a channel serving those.
# The first package is named after the recipe directory.
publish() {
  local dir="$TEST_ROOT/www/$1/$2" db name file; shift 2
  db=$(mktemp -d); mkdir -p "$dir"
  while (( $# )); do
    for name in "$(basename "$(grep -l "^pkgbase=$1\$" "$TEST_ROOT"/pkgbuilds/*/PKGBUILD | xargs dirname)")" "$1-extra"; do
      file="$name-$2-any.pkg.tar.zst"
      printf 'bytes of %s\n' "$file" > "$dir/$file"
      mkdir "$db/$name-$2"
      printf '%%FILENAME%%\n%s\n\n%%NAME%%\n%s\n\n%%BASE%%\n%s\n\n%%VERSION%%\n%s\n\n%%SHA256SUM%%\n%s\n' \
        "$file" "$name" "$1" "$2" "$(sha256sum "$dir/$file" | cut -d' ' -f1)" > "$db/$name-$2/desc"
    done
    shift 2
  done
  tar --zstd -cf "$dir/omarchy.db.tar.zst" -C "$db" .
  rm -rf "$db"
}
publish edge x86_64 split-any 2-1 renamed 2-1 fast-any 2-1 everywhere 2-1
publish edge aarch64 split-any 1-1 renamed 1-1 everywhere 2-1
publish rc x86_64 fast-any 2-1
publish rc aarch64 fast-any 1-1
publish stable x86_64 fast-any 2-1
publish stable aarch64 fast-any 2-1

python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$TEST_ROOT/www" > "$TEST_ROOT/server.log" 2>&1 &
server=$!
for _ in {1..50}; do
  port=$(sed -nE 's/.*port ([0-9]+).*/\1/p' "$TEST_ROOT/server.log" | head -1)
  [[ -n "$port" ]] && break
  sleep 0.1
done
export OMARCHY_PUBLISHED_REPO_URL="http://127.0.0.1:$port"

slots() { "$TEST_ROOT/bin/publish-slots" "$@" | paste -sd' '; }
expect() { [[ "$2" == "$3" ]] || { printf 'FAIL: %s\n  expected: %s\n  got:      %s\n' "$1" "$2" "$3"; exit 1; }; }

expect "arch=any current in one architecture only" \
  "edge/x86_64 current edge/aarch64 missing" "$(slots split-any edge 'x86_64 aarch64')"
expect "comma-separated arguments, as the publish plan passes them" \
  "edge/x86_64 current edge/aarch64 missing" "$(slots split-any edge x86_64,aarch64)"
expect "fast ring: every channel and architecture is asked" \
  "edge/x86_64 current edge/aarch64 missing rc/x86_64 current rc/aarch64 missing stable/x86_64 current stable/aarch64 current" \
  "$(slots fast-any 'edge rc stable' 'x86_64 aarch64')"
expect "a recipe directory that differs from its pkgbase" \
  "edge/x86_64 current edge/aarch64 missing" "$(slots renamed-dir edge 'x86_64 aarch64')"
expect "current everywhere" \
  "edge/x86_64 current edge/aarch64 current" "$(slots everywhere edge 'x86_64 aarch64')"
if "$TEST_ROOT/bin/publish-slots" split-any edge riscv64 > /dev/null 2>&1; then
  echo "FAIL: an unknown architecture must not plan"; exit 1
fi
echo "PASS: publish-slots reports each slot, and never calls an unplanned one current"

out="$TEST_ROOT/out"
"$TEST_ROOT/bin/fetch-published" --mirror edge --arch x86_64 --package split-any --out "$out" > /dev/null
expect "every file of the pkgbase, and only those" \
  "split-any-2-1-any.pkg.tar.zst split-any-extra-2-1-any.pkg.tar.zst" "$(ls "$out" | paste -sd' ')"
cmp -s "$out/split-any-2-1-any.pkg.tar.zst" "$TEST_ROOT/www/edge/x86_64/split-any-2-1-any.pkg.tar.zst"

rm -rf "$out"
"$TEST_ROOT/bin/fetch-published" --mirror edge --arch x86_64 --package renamed-dir --out "$out" > /dev/null
expect "a recipe directory that differs from its pkgbase" \
  "renamed-dir-2-1-any.pkg.tar.zst renamed-extra-2-1-any.pkg.tar.zst" "$(ls "$out" | paste -sd' ')"

rm -rf "$out"
echo tampered > "$TEST_ROOT/www/edge/x86_64/split-any-extra-2-1-any.pkg.tar.zst"
if "$TEST_ROOT/bin/fetch-published" --mirror edge --arch x86_64 --package split-any --out "$out" > /dev/null 2>&1; then
  echo "FAIL: a file that does not match the database must not be fetched"; exit 1
fi
[[ ! -e "$out" ]] || { echo "FAIL: a failed fetch left files behind"; exit 1; }
if "$TEST_ROOT/bin/fetch-published" --mirror edge --arch aarch64 --package fast-any --out "$out" > /dev/null 2>&1; then
  echo "FAIL: a channel without the package must fail"; exit 1
fi

# Half a split package, or its halves at two versions, is not one build.
incomplete() {
  if "$TEST_ROOT/bin/fetch-published" --mirror edge --arch x86_64 --package split-any --out "$out" > /dev/null 2>&1; then
    echo "FAIL: $1 must not be copied"; exit 1
  fi
  [[ ! -e "$out" ]] || { echo "FAIL: $1 left files behind"; exit 1; }
}
publish edge x86_64 split-any 2-1
rm -rf "$TEST_ROOT/db"; mkdir "$TEST_ROOT/db"
tar --zstd -xf "$TEST_ROOT/www/edge/x86_64/omarchy.db.tar.zst" -C "$TEST_ROOT/db"
sed -i 's/^2-1$/1-1/' "$TEST_ROOT/db/split-any-extra-2-1/desc"
tar --zstd -cf "$TEST_ROOT/www/edge/x86_64/omarchy.db.tar.zst" -C "$TEST_ROOT/db" .
incomplete "a split package at two versions"
rm -rf "$TEST_ROOT/db/split-any-extra-2-1"
tar --zstd -cf "$TEST_ROOT/www/edge/x86_64/omarchy.db.tar.zst" -C "$TEST_ROOT/db" .
incomplete "a split package with one output absent"
echo "PASS: fetch-published copies exactly one complete published build or nothing"
