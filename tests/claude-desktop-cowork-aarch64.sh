#!/bin/bash
# Cowork on aarch64 needs the same VM stack as x86_64, via Arch's any-arch firmware.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PKGBUILD="$ROOT/pkgbuilds/claude-desktop/PKGBUILD"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

eval "$(awk '
  /^package\(\)/ { exit }
  { print }
' "$PKGBUILD")"

[[ ${optdepends_aarch64+x} ]] || fail "optdepends_aarch64 is not defined"

want=(qemu-system-aarch64 edk2-aarch64 virtiofsd)
for pkg in "${want[@]}"; do
  matched=0
  for dep in "${optdepends_aarch64[@]}"; do
    case "$dep" in
      "$pkg"|"$pkg:"*) matched=1 ;;
    esac
  done
  [[ $matched -eq 1 ]] || fail "optdepends_aarch64 missing $pkg (got: ${optdepends_aarch64[*]})"
done

# The Debian-compat virtiofsd path is the same on both arches. It must not be
# folded into the x86_64 OVMF shim block.
python3 - "$PKGBUILD" <<'PY' || fail "virtiofsd libexec symlink is still x86_64-only"
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
fn = re.search(r"package\(\)\s*\{(.*)\n\}", text, re.S)
if not fn:
    sys.exit("could not find package()")
body = fn.group(1)
# Strip the x86_64-only block so remaining body must still create the link.
stripped = re.sub(
    r"""if \[\[ "\$\{CARCH\}" == x86_64 \]\]; then.*?fi""",
    "",
    body,
    count=1,
    flags=re.S,
)
if "libexec/virtiofsd" not in stripped:
    sys.exit(1)
PY

printf 'PASS: claude-desktop declares aarch64 Cowork optdepends and virtiofsd shim\n'
