#!/bin/bash
# bin/unpublish-plan retires an entry only from a channel and architecture no
# recipe publishes it to, and refuses a package a recipe still publishes
# everywhere it was asked for.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

recipe() { # recipe <name> <arches> [package.json]
  mkdir -p "$T/pkgbuilds/$1/.omarchy"
  printf 'pkgname=%s\npkgver=1\npkgrel=1\narch=(%s)\n' "$1" "$2" > "$T/pkgbuilds/$1/PKGBUILD"
  echo "${3:-"{\"source\": \"local\"}"}" > "$T/pkgbuilds/$1/.omarchy/package.json"
}
recipe everywhere "x86_64 aarch64"
recipe arm-only "aarch64"
recipe icon-theme "any"
sed -i 's/^pkgname=icon-theme$/pkgbase=icons\npkgname=(icons-light icons-dark)/' "$T/pkgbuilds/icon-theme/PKGBUILD"

plan() { OMARCHY_PKGBUILDS="$T/pkgbuilds" "$ROOT/bin/unpublish-plan" "$@" 2>"$T/err"; }
line() { grep "^$1=" <<<"$out" | cut -d= -f2-; }

out=$(plan --channels "stable" arm-only gone) || fail "arm-only refused: $(cat "$T/err")"
[[ $(line RETIRE_STABLE_X86_64) == "arm-only gone" && $(line RETIRE_STABLE_AARCH64) == gone ]] &&
  pass "a dropped architecture and a removed recipe are retired, the rest kept" || fail "arch plan: $out"
[[ -z $(line RETIRE_RC_X86_64) ]] && pass "a channel not asked for is left alone" || fail "rc touched: $out"

plan --channels "edge rc stable" everywhere >/dev/null && fail "a package published everywhere was not refused"
grep -q "still published to every channel" "$T/err" && pass "a package still published everywhere asked for is refused" || fail "message: $(cat "$T/err")"
plan --channels "edge rc stable" icons >/dev/null && fail "a pkgbase built under another directory name was retired: $(cat "$T/err")"
pass "a pkgbase is matched to the recipe that builds it, whatever its directory is called"
plan --channels "rc" everywhere >/dev/null && fail "a package was retired from rc although its recipe publishes it there by promotion"
pass "a package with a recipe is refused for rc too, which promotion fills from edge"
plan --channels "stable beta" gone >/dev/null && fail "an unknown channel was accepted"
pass "an unknown channel is refused"
plan --channels "stable" 'bad name' >/dev/null && fail "a bad package name was accepted"
pass "a bad package name is refused"
plan --channels >/dev/null && fail "a bare --channels was accepted"
pass "a bare --channels is refused"

recipe broken "x86_64 aarch64"
sed -i '1i return 1' "$T/pkgbuilds/broken/PKGBUILD"
plan --channels "stable" gone >/dev/null && fail "a plan was made although a PKGBUILD could not be read"
grep -q "Cannot read pkgbuilds/broken/PKGBUILD" "$T/err" && pass "a PKGBUILD that can't be read stops the plan" || fail "message: $(cat "$T/err")"
