#!/bin/bash
set -euo pipefail

REPO_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
INSTALL_SCRIPT="$REPO_ROOT/pkgbuilds/dell-xps-touchpad-haptics/dell-xps-touchpad-haptics.install"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=/dev/null
source "$INSTALL_SCRIPT"

home="$TEST_ROOT/home"
config_dir="$home/.config/omarchy"
config_path="$config_dir/dell-haptic.conf"
protected_file="$TEST_ROOT/protected"
runuser_call="$TEST_ROOT/runuser-call"
chown_call="$TEST_ROOT/chown-call"
runuser_stub="$TEST_ROOT/runuser"
mkdir -p "$config_dir"
printf 'must remain unchanged\n' >"$protected_file"
ln -s "$protected_file" "$config_path"

chown() {
  printf '%s\n' "$*" >>"$chown_call"
}

_ensure_user_config test-user "$home"
[[ ! -e $chown_call ]]
[[ ! -e $runuser_call ]]
[[ $(cat "$protected_file") == 'must remain unchanged' ]]

rm "$config_path"
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  '[[ $1 == --user && $2 == test-user && $3 == -- && $4 == /usr/bin/env ]]' \
  '[[ $5 == "HOME=$EXPECTED_HOME" && $6 == USER=test-user && $7 == LOGNAME=test-user ]]' \
  '[[ $8 == /usr/bin/dell-xps-touchpad-haptics && $9 == set && ${10} == high ]]' \
  'printf "%s\n" "$*" >>"$RUNUSER_CALL"' \
  'printf "INTENSITY=100\n" >"$EXPECTED_CONFIG"' >"$runuser_stub"
chmod +x "$runuser_stub"
export EXPECTED_HOME="$home"
export EXPECTED_CONFIG="$config_path"
export RUNUSER_CALL="$runuser_call"
_runuser_path="$runuser_stub"

_ensure_user_config test-user "$home"
[[ ! -e $chown_call ]]
[[ -f $config_path && ! -L $config_path ]]
[[ $(cat "$config_path") == 'INTENSITY=100' ]]
grep -q '^--user test-user -- /usr/bin/env ' "$runuser_call"

echo 'PASS: user config creation drops privileges and never chowns symlink targets'
