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
expect_fail() { # expect_fail [--contains] <label> <expected-stderr> <plan args...>
  local mode=exact
  if [[ ${1:-} == --contains ]]; then
    mode=contains
    shift
  fi
  local label=$1 expected=$2
  shift 2
  if plan "$@" >"$T/out"; then
    fail "$label (unexpected success: $(cat "$T/out"))"
  fi
  [[ ! -s "$T/out" ]] || fail "$label (unexpected stdout: $(cat -v "$T/out"))"
  if [[ $mode == contains ]]; then
    if grep -qF "$expected" "$T/err"; then pass "$label"; else fail "$label (stderr: $(cat -v "$T/err"))"; fi
  else
    printf '%s\n' "$expected" > "$T/expected-err"
    if cmp -s "$T/err" "$T/expected-err"; then pass "$label"; else fail "$label (stderr: $(cat -v "$T/err"))"; fi
  fi
}

out=$(plan --channels "stable" arm-only gone) || fail "arm-only refused: $(cat "$T/err")"
[[ $(line RETIRE_STABLE_X86_64) == "arm-only gone" && $(line RETIRE_STABLE_AARCH64) == gone ]] &&
  pass "a dropped architecture and a removed recipe are retired, the rest kept" || fail "arch plan: $out"
for var in RETIRE_EDGE_X86_64 RETIRE_EDGE_AARCH64 RETIRE_RC_X86_64 RETIRE_RC_AARCH64; do
  grep -qx "$var=" <<<"$out" || fail "unasked channel line missing or non-empty ($var): $out"
done
pass "unasked channels emit empty assignments"

expect_fail --contains "a package still published everywhere asked for is refused" \
  "still published to every channel" \
  --channels "edge rc stable" everywhere
expect_fail --contains "a mixed refusal leaves stdout empty" \
  "still published to every channel" \
  --channels "edge rc stable" gone everywhere
expect_fail --contains "a pkgbase is matched to the recipe that builds it, whatever its directory is called" \
  "still published to every channel" \
  --channels "edge rc stable" icons
expect_fail --contains "a package with a recipe is refused for rc too, which promotion fills from edge" \
  "still published to every channel" \
  --channels "rc" everywhere
expect_fail "an unknown channel is refused" \
  "::error::Unknown channel: beta" \
  --channels "stable beta" gone
expect_fail "a bad package name is refused" \
  "::error::Not a package name: bad name" \
  --channels "stable" 'bad name'
expect_fail "a leading-dash package name after a valid one is refused with empty stdout" \
  "::error::Not a package name: --remote" \
  --channels "stable" gone --remote
expect_fail "whitespace-only channels are refused" \
  '::error::usage: unpublish-plan --channels "<edge rc stable>" <pkgbase...>' \
  --channels "   " gone
expect_fail "valid channels with zero packages are refused" \
  '::error::usage: unpublish-plan --channels "<edge rc stable>" <pkgbase...>' \
  --channels "stable"
expect_fail "multiline channels are refused" \
  "::error::Channels must be a single space-separated line" \
  --channels $'stable\nedge' gone
expect_fail "multiline package input emits a single safe annotation" \
  "::error::Package names must be single-line" \
  --channels "stable" $'foo\n::warning::injected'
expect_fail "a backslash in channels is not unescaped" \
  '::error::Unknown channel: sta\ble' \
  --channels 'sta\ble' gone
mkdir -p "$T/glob-cwd" && : > "$T/glob-cwd/stable"
(cd "$T/glob-cwd" && expect_fail "a globbing channel name is refused without expansion" \
  "::error::Unknown channel: st*" \
  --channels "st*" gone)
expect_fail "a bare --channels is refused" \
  '::error::usage: unpublish-plan --channels "<edge rc stable>" <pkgbase...>' \
  --channels

recipe broken "x86_64 aarch64"
sed -i '1i return 1' "$T/pkgbuilds/broken/PKGBUILD"
expect_fail --contains "a PKGBUILD that can't be read stops the plan" \
  "Cannot read pkgbuilds/broken/PKGBUILD" \
  --channels "stable" gone
