#!/bin/bash
# Self-test for helpers/package-owners.sh against packages that makepkg
# builds under fakeroot. Needs makepkg and bsdtar (run in the Arch test
# container).
# shellcheck disable=SC2016 # package() bodies are expanded by makepkg, not here
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
source "$ROOT/helpers/package-owners.sh"
T=$(mktemp -d); chmod 755 "$T"; trap 'rm -rf "$T"' EXIT

# A vendor tarball made by a CI runner records its files as uid 1001, as
# Bitwarden's arm64 release does.
mkdir -p "$T/vendor/app"
echo app > "$T/vendor/app/app"
bsdtar -czf "$T/vendor.tar.gz" --uid 1001 --gid 1001 -C "$T/vendor" app

mkpkg() { # mkpkg <name> <package() body>
  local d="$T/src/$1"
  mkdir -p "$d"
  cp "$T/vendor.tar.gz" "$d/"
  printf 'pkgname=%s\npkgver=1\npkgrel=1\narch=(any)\nsource=(vendor.tar.gz)\nnoextract=(vendor.tar.gz)\nsha256sums=(SKIP)\npackage() {\n%s\n}\n' "$1" "$2" > "$d/PKGBUILD"
  if (( EUID == 0 )); then
    id -u fixture >/dev/null 2>&1 || useradd -m fixture
    chmod 755 "$T/src"
    chown -R fixture "$d"
    (cd "$d" && runuser -u fixture -- env PKGEXT=.pkg.tar.zst makepkg -f --nodeps >/dev/null 2>&1)
  else
    (cd "$d" && PKGEXT=.pkg.tar.zst makepkg -f --nodeps >/dev/null 2>&1)
  fi
  echo "$d/$1-1-1-any.pkg.tar.zst"
}
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; cat "$T/out"; exit 1; }

runner=$(mkpkg runner 'install -d "$pkgdir/opt/app"; bsdtar -xf vendor.tar.gz -C "$pkgdir/opt/app"')
if check_package_owners "$runner" >"$T/out"; then
  fail "a vendor tarball extracted under fakeroot keeps uid 1001"
fi
grep -q ' 1001 *1001 .* opt/app/app/app$' "$T/out" || fail "the refusal does not name the file and its owner"
pass "refuses the runner's uid from a vendor tarball"

root=$(mkpkg root 'install -d "$pkgdir/opt/app"; bsdtar --no-same-owner -xf vendor.tar.gz -C "$pkgdir/opt/app"')
check_package_owners "$root" >"$T/out" || fail "--no-same-owner extraction is refused"
pass "accepts the same tarball extracted with --no-same-owner"

games=$(mkpkg games 'install -Dm644 /dev/null "$pkgdir/var/games/app/scores"; chgrp 50 "$pkgdir/var/games/app/scores"')
check_package_owners "$games" >"$T/out" || fail "a file in group games is refused"
pass "accepts a system group with a fixed ID"

users=$(mkpkg users 'install -Dm644 /dev/null "$pkgdir/usr/share/app/data"; chgrp 100 "$pkgdir/usr/share/app/data"')
if check_package_owners "$users" >"$T/out"; then
  fail "a file in group users (100) is accepted"
fi
pass "refuses group users"

if check_package_owners "$root" "$runner" >"$T/out"; then
  fail "a refused file is hidden by an accepted one before it"
fi
pass "refuses when any of several files breaks the rule"

if check_package_owners "$T/missing.pkg.tar.zst" >"$T/out" 2>&1; then
  fail "a file that cannot be read is accepted"
fi
pass "refuses a file it cannot read"
