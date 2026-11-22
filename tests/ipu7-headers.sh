#!/bin/bash
set -euo pipefail

REPO_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
PKGBUILD=${1:-"$REPO_ROOT/pkgbuilds/intel-ipu7-camera/PKGBUILD"}
(( $# <= 1 )) && [[ -f $PKGBUILD ]] || { echo 'Usage: ipu7-headers.sh [PKGBUILD]' >&2; exit 1; }

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
has_package() {
  local sought=$1 package
  shift
  for package in "$@"; do
    [[ $package == "$sought" ]] && return 0
  done
  return 1
}

# Sourcing reads the real metadata and defines the real check(), without
# running prepare(), build(), package(), or any hardware operation.
source "$PKGBUILD"
for package in linux-headers linux-omarchy-headers; do
  if has_package "$package" "${depends[@]}"; then
    fail "$package must not be a runtime dependency"
  fi
done
declare -p checkdepends >/dev/null 2>&1 || fail 'checkdepends is missing'
has_package linux-omarchy-headers "${checkdepends[@]}" || fail 'Omarchy headers are missing from checkdepends'
if has_package linux-headers "${checkdepends[@]}"; then
  fail 'Arch headers must not be a check dependency'
fi

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ipu7-headers.XXXXXXXX")
cleanup() {
  if [[ -n ${TEST_ROOT:-} && -d $TEST_ROOT && ${TEST_ROOT##*/} == ipu7-headers.* ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT
srcdir="$TEST_ROOT/src"
TEST_KERNEL_BUILD="$TEST_ROOT/kernel/build"
TEST_CALLS="$TEST_ROOT/calls"
export TEST_KERNEL_BUILD TEST_CALLS srcdir
mkdir -p "$TEST_ROOT/bin" "$srcdir/ipu7-drivers/drivers/media/pci/intel/ipu7/psys" \
  "$TEST_KERNEL_BUILD/scripts"
printf '%s\n' 'fixture kernel Makefile' >"$TEST_KERNEL_BUILD/Makefile"
printf '%s\n' 'fixture patch' >"$srcdir/0005-ipu7-psys-harden-userptr-pinning.patch"
printf '%s\n' 'fixture source' >"$srcdir/check-userptr-range.c"
cat >"$srcdir/ipu7-drivers/drivers/media/pci/intel/ipu7/psys/ipu-psys.c" <<'EOF'
kvmalloc_array(npages, sizeof(*pages)
attach->len > MAX_RW_COUNT
attach_fail:
	kbuf->db_attach = NULL;
EOF

# Each command accepts only the one call made by check(). All output stays in
# the disposable fixture, including the stand-in compiled program and module.
cat >"$TEST_ROOT/bin/stub" <<'EOF'
#!/bin/bash
set -euo pipefail
case ${0##*/} in
  stub) [[ ${1:-} == '--probe' ]] || exit 1 ;;
  pacman)
    printf 'pacman %s\n' "$*" >>"$TEST_CALLS"
    if (( $# != 2 )) || [[ $1 != '-Qql' || $2 != 'linux-omarchy-headers' ]]; then
      printf 'Unexpected pacman query: %s\n' "$*" >&2
      exit 1
    fi
    [[ $TEST_SCENARIO != 'missing-package' ]] || exit 1
    if [[ $TEST_SCENARIO == 'missing-makefile' ]]; then
      printf '%s\n' "$TEST_KERNEL_BUILD/missing/build/Makefile"
    else
      printf '%s\n' "$TEST_KERNEL_BUILD/Makefile"
    fi
    ;;
  cc)
    printf 'cc %s\n' "$*" >>"$TEST_CALLS"
    (( $# == 8 )) && [[ $6 == "$srcdir/check-userptr-range.c" && $7 == '-o' && $8 == "$srcdir/check-userptr-range" ]] || exit 1
    cat >"$8" <<'PROGRAM'
#!/bin/bash
printf '%s\n' 'userptr fixture ran' >>"$TEST_CALLS"
PROGRAM
    chmod +x "$8"
    ;;
  make)
    printf 'make %s\n' "$*" >>"$TEST_CALLS"
    (( $# == 4 )) && [[ $1 == '-C' && $2 == "$srcdir/ipu7-drivers-check" && $3 == 'BUILD_INTEL_IPU_ACPI=1' && $4 == "KERNEL_SRC=/$TEST_KERNEL_BUILD" ]] || exit 1
    mkdir -p "$2/drivers/media/pci/intel/ipu7/psys"
    printf '%s\n' 'fixture module' >"$2/drivers/media/pci/intel/ipu7/psys/intel-ipu7-psys.ko"
    ;;
  checkpatch.pl)
    printf 'checkpatch %s\n' "$*" >>"$TEST_CALLS"
    (( $# == 4 )) && [[ $1 == '--no-tree' && $2 == '--strict' && $3 == '--no-signoff' && $4 == '0005-ipu7-psys-harden-userptr-pinning.patch' ]] || exit 1
    [[ -f $4 ]] || exit 1
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/stub"
"$TEST_ROOT/bin/stub" --probe 2>/dev/null || fail 'Set TMPDIR to an executable temporary directory for the test fixtures'
for command in pacman cc make; do ln -s stub "$TEST_ROOT/bin/$command"; done
ln -s "$TEST_ROOT/bin/stub" "$TEST_KERNEL_BUILD/scripts/checkpatch.pl"
export PATH="$TEST_ROOT/bin:$PATH"

TEST_SCENARIO=success
export TEST_SCENARIO
: >"$TEST_CALLS"
check || fail 'check() rejected valid Omarchy headers fixture'
grep -Fxq 'pacman -Qql linux-omarchy-headers' "$TEST_CALLS" || fail 'Omarchy headers were not queried'
grep -Fxq 'userptr fixture ran' "$TEST_CALLS" || fail 'compiled fixture was not run'
grep -Fxq 'checkpatch --no-tree --strict --no-signoff 0005-ipu7-psys-harden-userptr-pinning.patch' "$TEST_CALLS" || fail 'checkpatch was not reached'
grep -Fxq "make -C $srcdir/ipu7-drivers-check BUILD_INTEL_IPU_ACPI=1 KERNEL_SRC=/$TEST_KERNEL_BUILD" "$TEST_CALLS" || fail 'module build did not use Omarchy headers'

for TEST_SCENARIO in missing-package missing-makefile; do
  : >"$TEST_CALLS"
  if check; then fail "check() accepted $TEST_SCENARIO"; fi
  grep -Fxq 'pacman -Qql linux-omarchy-headers' "$TEST_CALLS" || fail "headers query skipped for $TEST_SCENARIO"
  if grep -Eq '^(checkpatch|make) ' "$TEST_CALLS"; then fail "build continued after $TEST_SCENARIO"; fi
done

echo 'PASS: IPU7 header metadata, Omarchy build path, and missing-header failures'
