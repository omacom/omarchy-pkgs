#!/bin/bash
# Run the real installer against temporary paths and an unprivileged account.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
if (( EUID != 0 )); then
  echo 'Run this regression test as root (or sudo) to exercise real runuser.' >&2
  exit 1
fi
python3 "$ROOT/tests/p16-audio-install-user-units.py"
