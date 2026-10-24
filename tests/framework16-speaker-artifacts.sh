#!/bin/bash
# Check a settings/runtime package pair built with OMARCHY_SRC pointing at
# the Framework speaker fix. Older pinned sources intentionally lack it.
set -euo pipefail

if (( $# != 2 )); then
  echo "Usage: $0 SETTINGS_PACKAGE RUNTIME_PACKAGE" >&2
  exit 2
fi
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/settings" "$scratch/runtime"
tar -xf "$1" -C "$scratch/settings"
tar -xf "$2" -C "$scratch/runtime"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

unit=omarchy-framework16-speaker-levels.service
vendor="$scratch/settings/usr/lib/systemd/user/$unit"
[[ -f $vendor && ! -L $vendor ]] || fail 'settings package has no vendor speaker unit'
[[ $(stat -c '%a' "$vendor") == 644 ]] || fail 'vendor unit permissions are not 0644'
cmp -s "$vendor" "$scratch/settings/usr/share/omarchy/default/systemd/user/$unit" ||
  fail 'installed vendor unit differs from the source unit'
override="$scratch/settings/etc/skel/.config/systemd/user/$unit"
[[ ! -e $override && ! -L $override ]] || fail 'a user unit would shadow the vendor unit'

executable=$(sed -n 's/^ExecStart=//p' "$vendor")
[[ $executable == "/usr/bin/omarchy-apply-framework16-speaker-levels" ]] ||
  fail 'vendor unit does not use the apply helper'
[[ -f $scratch/runtime$executable && ! -L $scratch/runtime$executable && -x $scratch/runtime$executable ]] ||
  fail 'runtime package does not ship the executable named by ExecStart'
[[ $(readlink "$scratch/runtime/usr/share/omarchy/bin/${executable##*/}") == "$executable" ]] ||
  fail 'runtime helper link does not point at the packaged executable'
[[ -f $scratch/settings/usr/share/omarchy/default/wireplumber/wireplumber.conf.d/framework16-ai300-soft-mixer.conf ]] ||
  fail 'settings package has no Framework software-mixer rule'
echo 'PASS: package pair ships the vendor unit, its executable, and the mixer rule'
