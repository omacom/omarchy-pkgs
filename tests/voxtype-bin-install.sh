#!/bin/bash
# voxtype-bin.install: a host gets a Whisper CPU build it can run, on a fresh
# install and on an upgrade from a release that had no baseline build.
set -euo pipefail

REPO_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
INSTALL_SCRIPT="$REPO_ROOT/pkgbuilds/voxtype-bin/voxtype-bin.install"
TEST_ROOT=$(realpath "$(mktemp -d)")
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

# The hook keeps upgrade state in /run and restores backends from
# /usr/lib/voxtype; move both into the test directory.
_backend_state="$SAVED"
_backend_root="$TEST_ROOT/lib"

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

# What another local user could have written into the state file: only a
# binary under the backend directory may become /usr/bin/voxtype.
touch "$TEST_ROOT/payload"
ln -s "$TEST_ROOT/payload" "$TEST_ROOT/lib/voxtype-escape"
upgrade "sse4_2 avx2" "$TEST_ROOT/payload" avx2 /usr/lib/voxtype/voxtype-avx2 \
  "a saved path outside the backend directory is ignored"
upgrade "sse4_2 avx2" "$TEST_ROOT/lib/../payload" avx2 /usr/lib/voxtype/voxtype-avx2 \
  "a saved path that climbs out of the backend directory is ignored"
upgrade "sse4_2 avx2" "$TEST_ROOT/lib/voxtype-escape" avx2 /usr/lib/voxtype/voxtype-avx2 \
  "a saved symlink that leaves the backend directory is ignored"
upgrade "sse4_2 avx2" "$TEST_ROOT/lib/voxtype-missing" avx2 /usr/lib/voxtype/voxtype-avx2 \
  "a saved backend that is gone falls back to the default"
[[ ! -e $SAVED ]] || fail "the state file survives post_upgrade"
pass "post_upgrade consumes the state file"

# pre_upgrade must not hand a file an interrupted upgrade left to the next one.
printf '%s\n' "$TEST_ROOT/lib/voxtype-vulkan" >"$SAVED"
_resolve_active_binary() { :; }
pre_upgrade
[[ ! -e $SAVED ]] || fail "pre_upgrade kept a stale state file when it found no launcher"
pass "pre_upgrade drops a stale state file when it finds no launcher"
_resolve_active_binary() { echo "$TEST_ROOT/lib/voxtype-avx2"; }
pre_upgrade
[[ $(<"$SAVED") == "$TEST_ROOT/lib/voxtype-avx2" ]] || fail "pre_upgrade did not save the launcher's backend"
pass "pre_upgrade saves the launcher's backend"
