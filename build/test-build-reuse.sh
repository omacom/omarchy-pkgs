#!/bin/bash
# Regression tests for reusing complete split builds; no network or container.
set -euo pipefail
root=$(realpath "${BASH_SOURCE[0]%/*}/..")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/recipes/example/.omarchy" "$tmp/staged" "$tmp/final" "$tmp/archive"
cat > "$tmp/recipes/example/PKGBUILD" <<'EOF'
pkgbase=example
pkgname=(example-runtime example-headers)
pkgver=1.0
pkgrel=1
arch=(x86_64)
EOF
echo '{"source":"local"}' > "$tmp/recipes/example/.omarchy/package.json"
archive() {
  printf 'pkgname = %s\npkgbase = example\npkgver = %s\narch = x86_64\n' "$1" "$2" > "$tmp/archive/.PKGINFO"
  bsdtar -cf "$tmp/staged/$1-$2-x86_64.pkg.tar.zst" --zstd -C "$tmp/archive" .PKGINFO
}
plan() {
  ARCH=x86_64 DRY_RUN=true PACKAGES=example PKGBUILDS_DIR="$tmp/recipes" \
    BUILD_OUTPUT_DIR="$tmp/staged" FINAL_OUTPUT_DIR="$tmp/final" HELPERS_DIR="$root/helpers" \
    "$root/build/build.sh" > "$tmp/plan"
}
needs_build() { plan; grep -q '1 package(s) need building: example' "$tmp/plan"; }
is_current() { plan; grep -q 'All packages are up to date!' "$tmp/plan"; }
needs_build
archive example-runtime 1.0-1
needs_build
archive example-headers 1.0-1
is_current
rm "$tmp/staged/example-headers-1.0-1-x86_64.pkg.tar.zst"
archive example-headers 0.9-1
needs_build
archive example-headers 1.0-1
echo corrupt > "$tmp/staged/example-headers-1.0-1-x86_64.pkg.tar.zst"
needs_build
archive example-headers 1.0-1
sed -i 's/pkgrel=1/pkgrel=2/' "$tmp/recipes/example/PKGBUILD"
needs_build
sed -i 's/pkgrel=2/pkgrel=1/' "$tmp/recipes/example/PKGBUILD"

# Published DB lookup must not use one split output as proof of the whole base.
rm "$tmp/staged/"*.pkg.tar.zst
mkdir -p "$tmp/db/example-runtime-1.0-1" "$tmp/db/example-headers-1.0-1"
for output in example-runtime example-headers; do
  printf '%%NAME%%\n%s\n\n%%BASE%%\nexample\n\n%%VERSION%%\n1.0-1\n\n' "$output" > "$tmp/db/$output-1.0-1/desc"
done
bsdtar -cf "$tmp/final/omarchy.db.tar.zst" --zstd -C "$tmp/db" example-runtime-1.0-1
needs_build
bsdtar -cf "$tmp/final/omarchy.db.tar.zst" --zstd -C "$tmp/db" example-runtime-1.0-1 example-headers-1.0-1
is_current
sed -i 's/1.0-1/0.9-1/' "$tmp/db/example-headers-1.0-1/desc"
bsdtar -cf "$tmp/final/omarchy.db.tar.zst" --zstd -C "$tmp/db" example-runtime-1.0-1 example-headers-1.0-1
needs_build
echo 'PASS: complete, missing, stale, corrupt and repackaged split outputs; incomplete/mixed published DBs'
