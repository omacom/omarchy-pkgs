#!/bin/bash
# Exercise install hooks without modifying the host's groups or /opt files.
set -euo pipefail
BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

declare -A groups=()
declare -A owners=()
group_creations=0
fail_groupadd=false
fail_chgrp=false
fail_browser_chmod=false

getent() {
  [[ $1 == group && -v groups[$2] ]] || return 2
  printf '%s:x:1001:\n' "$2"
}

groupadd() {
  [[ $fail_groupadd == false ]] || return 1
  [[ ! -v groups[$1] ]]
  groups[$1]=1
  group_creations=$((group_creations + 1))
}

groupdel() {
  [[ -v groups[$1] ]]
  unset 'groups[$1]'
}

chgrp() {
  [[ $fail_chgrp == false ]] || return 1
  [[ -v groups[$1] ]]
  owners[$2]=$1
}

chmod() {
  [[ $1 == g+s ]]
  if [[ $2 == /opt/1Password/1Password-BrowserSupport && $fail_browser_chmod == true ]]; then
    return 1
  fi
  case $2 in
    /opt/1Password/1Password-BrowserSupport|/opt/1Password/1password-mcp)
      command chmod "$1" "$TEST_ROOT/${2##*/}"
      ;;
    *) return 1 ;;
  esac
}

reset_modes() {
  touch "$TEST_ROOT/1Password-BrowserSupport" "$TEST_ROOT/1password-mcp"
  command chmod 755 "$TEST_ROOT/1Password-BrowserSupport" "$TEST_ROOT/1password-mcp"
}

assert_helpers() {
  [[ ${owners[/opt/1Password/1Password-BrowserSupport]} == onepassword ]]
  [[ ${owners[/opt/1Password/1password-mcp]} == onepassword-mcp ]]
  [[ $(stat -c %a "$TEST_ROOT/1Password-BrowserSupport") == 2755 ]]
  [[ $(stat -c %a "$TEST_ROOT/1password-mcp") == 2755 ]]
}

source "$BUILD_ROOT/pkgbuilds/1password/1password.install"

reset_modes
pre_install
post_install
assert_helpers
[[ $group_creations == 2 ]]
echo 'PASS: fresh install configures both helpers'

# Model an old installation with only the browser group, then unpacked files.
unset 'groups[onepassword-mcp]'
reset_modes
pre_upgrade
post_upgrade
assert_helpers
[[ $group_creations == 3 ]]
echo 'PASS: upgrade creates the missing MCP group'

reset_modes
pre_upgrade
post_upgrade
assert_helpers
[[ $group_creations == 3 ]]
echo 'PASS: subsequent upgrades reuse groups and restore setgid'

post_remove
[[ ${#groups[@]} == 0 ]]
post_remove
echo 'PASS: removal tolerates absent groups'

reset_modes
fail_groupadd=true
if setup_mcp_helper; then
  echo 'FAIL: group creation error was ignored' >&2
  exit 1
fi
[[ $(stat -c %a "$TEST_ROOT/1password-mcp") == 755 ]]
fail_groupadd=false
groups[onepassword-mcp]=1
fail_chgrp=true
if setup_mcp_helper; then
  echo 'FAIL: group ownership error was ignored' >&2
  exit 1
fi
[[ $(stat -c %a "$TEST_ROOT/1password-mcp") == 755 ]]
echo 'PASS: setup failures do not enable setgid on the wrong group'

# Each post hook must configure MCP even when the browser helper fails.
fail_chgrp=false
for hook in post_install post_upgrade; do
  groups[onepassword]=1
  unset 'groups[onepassword-mcp]'
  reset_modes
  fail_browser_chmod=true
  if "$hook"; then
    echo "FAIL: $hook ignored browser helper failure" >&2
    exit 1
  fi
  [[ ${owners[/opt/1Password/1password-mcp]} == onepassword-mcp ]]
  [[ $(stat -c %a "$TEST_ROOT/1password-mcp") == 2755 ]]
  [[ $(stat -c %a "$TEST_ROOT/1Password-BrowserSupport") == 755 ]]
  echo "PASS: $hook configures MCP despite browser helper failure"

  reset_modes
  fail_browser_chmod=false
  unset 'groups[onepassword-mcp]'
  fail_groupadd=true
  if "$hook"; then
    echo "FAIL: $hook ignored MCP helper failure" >&2
    exit 1
  fi
  [[ $(stat -c %a "$TEST_ROOT/1Password-BrowserSupport") == 2755 ]]
  [[ $(stat -c %a "$TEST_ROOT/1password-mcp") == 755 ]]
  fail_groupadd=false
  echo "PASS: $hook reports MCP failure after configuring browser helper"
done
