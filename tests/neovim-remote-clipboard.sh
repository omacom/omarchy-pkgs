#!/bin/bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export TEST_PROVIDER="$root/pkgbuilds/omarchy-nvim/lua/config/remote_clipboard.lua"
export NVIM_LOG_FILE=$(mktemp)
trap 'rm -f "$NVIM_LOG_FILE"' EXIT
nvim --clean -n --headless -i NONE -l "$root/tests/neovim-remote-clipboard.lua"
