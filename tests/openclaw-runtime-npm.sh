#!/bin/bash
# openclaw's Gateway spawns npm at runtime; it cannot live in makedepends only.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PKGBUILD="$ROOT/pkgbuilds/openclaw/PKGBUILD"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Isolate PKGBUILD assignments from package() by sourcing in a subshell that
# only needs the metadata arrays.
eval "$(awk '
  /^package\(\)/ { exit }
  { print }
' "$PKGBUILD")"

found=0
for dep in "${depends[@]}"; do
  case "$dep" in
    npm|npm=*) found=1 ;;
  esac
done
[[ $found -eq 1 ]] || fail "depends does not include npm (got: ${depends[*]-})"

for dep in "${makedepends[@]-}"; do
  case "$dep" in
    npm|npm=*) fail "npm is already in depends; do not duplicate it in makedepends" ;;
  esac
done

printf 'PASS: openclaw runtime depends include npm\n'
