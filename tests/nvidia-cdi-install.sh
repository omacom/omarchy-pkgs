#!/bin/bash
# Check installer and upgrade policy without touching the host service manager.
set -euo pipefail
root=$(realpath "${BASH_SOURCE[0]%/*}/..")
source "$root/pkgbuilds/nvidia-container-toolkit/nvidia-container-toolkit.install"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
calls=$scratch/calls
systemctl() {
  printf '%s\n' "$*" >> "$calls"
  if [[ $1 == --quiet && $2 == is-enabled ]]; then
    return "$enabled_status"
  fi
}
systemd-notify() { return "$booted_status"; }

# Offline installation must arrange the next boot without probing the GPU or
# contacting a service manager in the installer host.
booted_status=1 enabled_status=0
post_install
[[ $(wc -l < "$calls") == 1 ]]
grep -Fxq 'preset nvidia-cdi-refresh.service nvidia-cdi-refresh.path' "$calls"

# The first upgrade from the old transaction hook must activate both units
# without waiting for them.
> "$calls"
booted_status=0
post_upgrade 1.20.0-1.2 1.20.0-1
grep -Fxq 'preset nvidia-cdi-refresh.service nvidia-cdi-refresh.path' "$calls"
grep -Fxq 'start --no-block nvidia-cdi-refresh.service' "$calls"
grep -Fxq 'start --no-block nvidia-cdi-refresh.path' "$calls"

# An administrator preset disabling the units must prevent activation, and a
# disabled last unit must not fail the scriptlet.
> "$calls"
enabled_status=1
post_install
if grep -q '^start ' "$calls"; then exit 1; fi

# Upgrades from packages that already ship the units must not reapply presets
# over an administrator decision.
for old in 1.20.0-1.1 1.20.0-1.2 1.20.0-2; do
  > "$calls"
  post_upgrade 1.20.1-1 "$old"
  [[ ! -s $calls ]]
done
echo 'PASS: offline install, old-package upgrade and administrator service policy'
