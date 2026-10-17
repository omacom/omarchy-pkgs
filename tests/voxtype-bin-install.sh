#!/bin/bash
# voxtype-bin.install: a host gets a Whisper CPU build it can run, on a fresh
# install and on an upgrade from a release that had no baseline build.
set -euo pipefail

REPO_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
INSTALL_SCRIPT="$REPO_ROOT/pkgbuilds/voxtype-bin/voxtype-bin.install"
TEST_ROOT=$(mktemp -d)
SAVED="$TEST_ROOT/backend-upgrade"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}
pass() {
  echo "ok - $1"
}

# shellcheck source=/dev/null
source "$INSTALL_SCRIPT"

# The hook keeps upgrade state in /tmp, where a real upgrade's could be; move
# it into the test directory.
eval "$(declare -f _preserve_or_set_backend | sed 's|/tmp/\.voxtype-backend-upgrade|${SAVED}|')"
declare -f _preserve_or_set_backend | grep -qF '${SAVED}' ||
  fail "the hook no longer keeps its upgrade state at /tmp/.voxtype-backend-upgrade"

cpu_flags=""
_cpu_has() { [[ " $cpu_flags " == *" $1 "* ]]; }
_install_active_binary() { printf '%s\n' "$1" >"$TEST_ROOT/active"; }
uname() { echo x86_64; }

# What an earlier release left behind: its saved backends are real files.
mkdir -p "$TEST_ROOT/lib"
touch "$TEST_ROOT/lib/voxtype-avx2" "$TEST_ROOT/lib/voxtype-avx512" "$TEST_ROOT/lib/voxtype-vulkan"

fresh() {
  local flags=$1 backend=$2 description=$3 out
  cpu_flags=$flags
  out=$(_set_default_backend)
  [[ $out == "$backend" && $(<"$TEST_ROOT/active") == "/usr/lib/voxtype/voxtype-$backend" ]] ||
    fail "$description: got $out -> $(<"$TEST_ROOT/active")"
  pass "$description"
}

upgrade() {
  local flags=$1 saved=$2 backend=$3 active=$4 description=$5 out
  cpu_flags=$flags
  printf '%s\n' "$saved" >"$SAVED"
  out=$(_preserve_or_set_backend)
  [[ $out == "$backend" && $(<"$TEST_ROOT/active") == "$active" ]] ||
    fail "$description: got $out -> $(<"$TEST_ROOT/active")"
  pass "$description"
}

fresh "sse4_2" baseline "a fresh install without AVX2 gets the baseline build"
fresh "sse4_2 avx2" avx2 "a fresh install with AVX2 gets the AVX2 build"
fresh "sse4_2 avx2 avx512f" avx512 "a fresh install with AVX-512 gets the AVX-512 build"

upgrade "sse4_2" "$TEST_ROOT/lib/voxtype-avx2" baseline /usr/lib/voxtype/voxtype-baseline \
  "an upgrade without AVX2 moves off the AVX2 build an older release picked"
upgrade "sse4_2 avx2" "$TEST_ROOT/lib/voxtype-avx512" avx2 /usr/lib/voxtype/voxtype-avx2 \
  "an upgrade without AVX-512 moves off the AVX-512 build"
upgrade "sse4_2 avx2" "$TEST_ROOT/lib/voxtype-avx2" avx2 "$TEST_ROOT/lib/voxtype-avx2" \
  "an upgrade keeps a CPU build the host can run"
upgrade "sse4_2" "$TEST_ROOT/lib/voxtype-vulkan" vulkan "$TEST_ROOT/lib/voxtype-vulkan" \
  "an upgrade keeps a GPU build the user chose"
