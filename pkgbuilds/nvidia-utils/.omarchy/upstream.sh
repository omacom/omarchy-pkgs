#!/bin/bash
# The NVIDIA driver follows Arch's nvidia-utils: the production release Arch
# ships, so x86_64 matches what Arch users run, and ARM gets the same release
# with the fixes nvidia-open-dkms carries. bin/bump-nvidia moves the driver and
# the kernels that build its modules together, and their "lockstep" group puts
# them in one PR. It has already rewritten the recipes, so this reports no
# release of its own for sync-upstream to apply.
set -euo pipefail

arch=$(curl -fsSL --retry 3 https://archlinux.org/packages/extra/x86_64/nvidia-utils/json/ | jq -er '.pkgver')
current=$(sed -n 's/^pkgver=//p' PKGBUILD)

if (( $(vercmp "$arch" "$current") > 0 )); then
  ../../bin/bump-nvidia "$arch" >&2
fi
echo '{}'
