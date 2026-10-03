#!/bin/bash
# The Gateway looks up npm on its own PATH. Omarchy's npm is mise's, and a
# user service does not see the login PATH, so the unit drop-in has to add it.
# The npm package stays a build dependency only.
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

for dep in "${depends[@]}"; do
  case "$dep" in
    npm|npm=*) fail "runtime depends include the npm package (${depends[*]-}); the gateway should use mise npm" ;;
  esac
done

found=0
for dep in "${makedepends[@]-}"; do
  case "$dep" in
    npm|npm=*) found=1 ;;
  esac
done
[[ $found -eq 1 ]] || fail "makedepends does not include npm (got: ${makedepends[*]-})"

dropin="$ROOT/pkgbuilds/openclaw/openclaw-gateway.service.d/mise-path.conf"
[[ -f $dropin ]] || fail "missing gateway drop-in $dropin"
grep -Fq 'openclaw-gateway.service.d/mise-path.conf' "$PKGBUILD" ||
  fail "PKGBUILD does not install the gateway PATH drop-in"
grep -Fq '%h/.local/share/mise/shims' "$dropin" ||
  fail "gateway drop-in does not put mise shims on PATH" "$(cat "$dropin")"
grep -Fq '%h/.local/bin' "$dropin" ||
  fail "gateway drop-in does not keep the user bin directory" "$(cat "$dropin")"

printf 'PASS: openclaw gateway drop-in exposes mise npm without an npm package dependency\n'
