#!/bin/bash
# The timer and builder must agree when an older archive remains published.
set -euo pipefail
BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/pkgbuilds" "$TEST_ROOT/state"
cp "$BUILD_ROOT/bin/check-versions" "$TEST_ROOT/bin/"
cp -r "$BUILD_ROOT/helpers" "$BUILD_ROOT/build" "$TEST_ROOT/"
export OMARCHY_STATE_DIR="$TEST_ROOT/state"
unset OMARCHY_REPO_ROOT OMARCHY_RC_PINS OMARCHY_DEFER_RUNTIME_DEPS

fixture() {
  local name=$1 version=$2 release=$3
  mkdir -p "$TEST_ROOT/pkgbuilds/$name/.omarchy"
  printf '{"source":"local","channels":["edge"]}\n' > "$TEST_ROOT/pkgbuilds/$name/.omarchy/package.json"
  cat > "$TEST_ROOT/pkgbuilds/$name/PKGBUILD" <<EOF
pkgname=$name
pkgver=$version
pkgrel=$release
arch=('x86_64' 'aarch64')
EOF
}
fixture omarchy 4.0.3 1
fixture omarchy-settings 4.0.3 1
fixture current 1 1
fixture update 2 1
fixture rebuild 1 2
fixture unindexed 1 1
fixture signature-only 1 1
fixture other-arch 1 1
fixture new-package 1 1

db_entry() {
  local name=$1 version=$2
  mkdir -p "$TEST_ROOT/db/$name-$version"
  printf '%%NAME%%\n%s\n\n%%BASE%%\n%s\n\n%%VERSION%%\n%s\n' "$name" "$name" "$version" > "$TEST_ROOT/db/$name-$version/desc"
}
db_entry omarchy 4.0.4rc1-1
db_entry omarchy-settings 4.0.4rc1-1
for package in current update rebuild; do db_entry "$package" 1-1; done
printf '%s\n' new-package other-arch rebuild signature-only update | sort > "$TEST_ROOT/expected"

for arch in x86_64 aarch64; do
  repo="$TEST_ROOT/pkgs.omarchy.org/edge/$arch"
  mkdir -p "$repo"
  tar --zstd -cf "$repo/omarchy.db.tar.zst" -C "$TEST_ROOT/db" .
  touch "$repo/omarchy-4.0.3-1-$arch.pkg.tar.zst"
  touch "$repo/omarchy-settings-4.0.3-1-any.pkg.tar.xz"
  touch "$repo/unindexed-1-1-$arch.pkg.tar.zst"
  touch "$repo/rebuild-1-1-$arch.pkg.tar.zst"
  touch "$repo/signature-only-1-1-$arch.pkg.tar.zst.sig"
  other=x86_64
  [[ "$arch" == x86_64 ]] && other=aarch64
  touch "$repo/other-arch-1-1-$other.pkg.tar.zst"

  "$TEST_ROOT/bin/check-versions" --arch "$arch" > "$TEST_ROOT/check.log" 2>&1
  sort "$TEST_ROOT/state/.sync-needed-edge-$arch" > "$TEST_ROOT/queue"
  diff -u "$TEST_ROOT/expected" "$TEST_ROOT/queue"

  for selection in '' 'omarchy omarchy-settings current update rebuild unindexed signature-only other-arch new-package'; do
    ARCH="$arch" MIRROR=edge DRY_RUN=true PACKAGES="$selection" \
      PKGBUILDS_DIR="$TEST_ROOT/pkgbuilds" HELPERS_DIR="$TEST_ROOT/helpers" \
      FINAL_OUTPUT_DIR="$repo" BUILD_PLAN_DIR="$TEST_ROOT/plan" \
      "$TEST_ROOT/build/build.sh" > "$TEST_ROOT/plan.log" 2>&1
    sort "$TEST_ROOT/plan/packages" > "$TEST_ROOT/planned"
    diff -u "$TEST_ROOT/queue" "$TEST_ROOT/planned"
    grep -q 'omarchy 4.0.3-1 - archive already published' "$TEST_ROOT/plan.log"
  done
  printf 'PASS: %s scheduler and explicit/unscoped plans skip retained archives, allow new versions and releases\n' "$arch"
done
