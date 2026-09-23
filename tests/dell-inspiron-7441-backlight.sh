#!/bin/bash
set -euo pipefail

REPO_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
APPLY_SCRIPT="$REPO_ROOT/pkgbuilds/dell-inspiron-7441-backlight/dell-inspiron-7441-backlight-apply"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=/dev/null
source "$APPLY_SCRIPT"

_dtb="$TEST_ROOT/boot/x1e80100-dell-inspiron-14-plus-7441.dtb"
_dtbo="$TEST_ROOT/overlay-v1.dtbo"
_state_dir="$TEST_ROOT/state"
mkdir -p "${_dtb%/*}"
printf 'overlay v1\n' >"$TEST_ROOT/overlay-v1.dtbo"
printf 'overlay v2\n' >"$TEST_ROOT/overlay-v2.dtbo"

# A fake DTB is a text file; the overlay appends its contents plus a marker
# line that stands in for the panel's backlight property.
fdtoverlay() {
  [[ $1 == -i && $3 == -o ]]
  [[ ! -e $FDTOVERLAY_FAIL ]] || return 1
  { cat "$2" "$5"; printf 'panel-backlight\n'; } >"$4"
}

fdtget() {
  [[ $2 == "$_panel" && $3 == backlight ]]
  grep -qx 'panel-backlight' "$1"
}

FDTOVERLAY_FAIL="$TEST_ROOT/fdtoverlay-fail"

expect_dtb() {
  local expected
  expected=$(printf '%s\n' "$@")
  [[ $(<"$_dtb") == "$expected" ]]
}

# Missing DTB: nothing to do, and no state is created.
apply_backlight_overlay >/dev/null
[[ ! -e $_dtb && ! -e $_state_dir ]]
echo 'PASS: a missing DTB is a successful no-op'

# Stock DTB: patched, stock copy saved, checksum recorded.
printf 'stock v1\n' >"$_dtb"
apply_backlight_overlay >/dev/null
expect_dtb 'stock v1' 'overlay v1' 'panel-backlight'
[[ $(<"$_state_dir/stock.dtb") == 'stock v1' ]]
[[ $(<"$_state_dir/patched.sha256") == "$(_sha256 "$_dtb")" ]]
[[ $(stat -c %a "$_dtb") == 644 ]]
echo 'PASS: the stock DTB is patched and saved'

# Re-running re-derives from the stock copy instead of stacking overlays.
apply_backlight_overlay >/dev/null
expect_dtb 'stock v1' 'overlay v1' 'panel-backlight'
echo 'PASS: re-applying is idempotent'

# A newer overlay replaces the old one on package upgrade.
_dtbo="$TEST_ROOT/overlay-v2.dtbo"
apply_backlight_overlay >/dev/null
expect_dtb 'stock v1' 'overlay v2' 'panel-backlight'
[[ $(<"$_state_dir/stock.dtb") == 'stock v1' ]]
echo 'PASS: a package upgrade replaces the previous overlay'

# A kernel upgrade installs a new stock DTB; it becomes the saved copy.
printf 'stock v2\n' >"$_dtb"
apply_backlight_overlay >/dev/null
expect_dtb 'stock v2' 'overlay v2' 'panel-backlight'
[[ $(<"$_state_dir/stock.dtb") == 'stock v2' ]]
echo 'PASS: a kernel upgrade is re-patched from its own stock DTB'

# A failed merge leaves the DTB and state untouched and reports failure.
printf 'stock v3\n' >"$_dtb"
touch "$FDTOVERLAY_FAIL"
if apply_backlight_overlay 2>/dev/null; then
  echo 'FAIL: a failed merge reported success' >&2
  exit 1
fi
rm "$FDTOVERLAY_FAIL"
expect_dtb 'stock v3'
[[ $(<"$_state_dir/stock.dtb") == 'stock v2' ]]
compgen -G "$_dtb.*" >/dev/null && { echo 'FAIL: temporary file left behind' >&2; exit 1; }
echo 'PASS: a failed merge leaves the DTB untouched'

# Restore puts the saved stock DTB back and clears state.
apply_backlight_overlay >/dev/null
restore_stock_dtb >/dev/null
expect_dtb 'stock v3'
[[ ! -e $_state_dir ]]
echo 'PASS: removal restores the stock DTB'

# Restore never overwrites a DTB this package did not write.
apply_backlight_overlay >/dev/null
printf 'stock v4\n' >"$_dtb"
restore_stock_dtb >/dev/null
expect_dtb 'stock v4'
[[ ! -e $_state_dir ]]
echo 'PASS: removal leaves a kernel-replaced DTB alone'

# Once the kernel wires the backlight itself, the package steps aside.
apply_backlight_overlay >/dev/null
printf 'upstream fixed\npanel-backlight\n' >"$_dtb"
apply_backlight_overlay >/dev/null
expect_dtb 'upstream fixed' 'panel-backlight'
[[ ! -e $_state_dir/stock.dtb && ! -e $_state_dir/patched.sha256 ]]
echo 'PASS: an upstream-fixed DTB is left unchanged'
