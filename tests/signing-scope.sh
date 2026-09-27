#!/bin/bash
# Offline signer handoff test with a fixed data-only package and disposable key.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/output" "$TEST_ROOT/publication" "$TEST_ROOT/policies/tool/.omarchy" "$TEST_ROOT/keyhome"
chmod 700 "$TEST_ROOT/keyhome"
printf '{"source":"local"}\n' > "$TEST_ROOT/policies/tool/.omarchy/package.json"

PACKAGE=tool-1-1-x86_64.pkg.tar.zst
python3 - "$TEST_ROOT" <<'PY'
import io
from pathlib import Path
import subprocess
import sys
import tarfile
root = Path(sys.argv[1])
info = b'pkgname = tool\npkgbase = tool\npkgver = 1-1\narch = x86_64\n'
buffer = io.BytesIO()
with tarfile.open(fileobj=buffer, mode='w') as archive:
    entry = tarfile.TarInfo('.PKGINFO')
    entry.size = len(info)
    archive.addfile(entry, io.BytesIO(info))
with (root / 'output/tool-1-1-x86_64.pkg.tar.zst').open('wb') as output:
    subprocess.run(['zstd', '-q', '-c'], input=buffer.getvalue(), stdout=output, check=True)
PY
printf '%s\n' "$PACKAGE" > "$TEST_ROOT/files"
python3 "$ROOT/helpers/package-scope.py" create --policy-root "$TEST_ROOT/policies" \
  --package tool --arch x86_64 --directory "$TEST_ROOT/output" --files "$TEST_ROOT/files" \
  > "$TEST_ROOT/publication/manifest.json"

# The production script has fixed container paths; substitute only its output
# mount for this host-side fixture. No production test hook is added.
sed "s|^BUILD_OUTPUT_DIR=.*|BUILD_OUTPUT_DIR=\"$TEST_ROOT/output\"|" "$ROOT/build/sign.sh" > "$TEST_ROOT/sign.sh"
export GNUPGHOME="$TEST_ROOT/keyhome"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
  --quick-generate-key 'Signing Test <sign@test.invalid>' ed25519 sign 0
gpg --batch --quiet --armor --export-secret-keys > "$TEST_ROOT/private.asc"
export GPG_PRIVATE_KEY
GPG_PRIVATE_KEY=$(cat "$TEST_ROOT/private.asc")
export GPG_PASSPHRASE=''
unset GNUPGHOME

run_signer() {
  ARCH=x86_64 MIRROR=edge PUBLICATION_DIR="$TEST_ROOT/publication" \
    PKGBUILDS_DIR="$TEST_ROOT/policies" HELPERS_DIR="$ROOT/helpers" \
    bash "$TEST_ROOT/sign.sh" > "$TEST_ROOT/sign.log" 2>&1
}
run_signer
[[ -f "$TEST_ROOT/publication/packages/$PACKAGE" ]]
[[ -f "$TEST_ROOT/publication/signatures/$PACKAGE.sig" ]]
[[ -f "$TEST_ROOT/publication/manifest.json.sig" ]]
gpgv --keyring "$TEST_ROOT/publication/signing-key.gpg" \
  "$TEST_ROOT/publication/manifest.json.sig" "$TEST_ROOT/publication/manifest.json" > /dev/null 2>&1
gpgv --keyring "$TEST_ROOT/publication/signing-key.gpg" \
  "$TEST_ROOT/publication/signatures/$PACKAGE.sig" "$TEST_ROOT/publication/packages/$PACKAGE" > /dev/null 2>&1
python3 "$ROOT/helpers/package-scope.py" verify --policy-root "$TEST_ROOT/policies" \
  --arch x86_64 --directory "$TEST_ROOT/publication/packages" \
  --manifest "$TEST_ROOT/publication/manifest.json" > /dev/null

echo 'changed builder bytes' >> "$TEST_ROOT/output/$PACKAGE"
if run_signer; then
  echo 'FAIL: changed archive was signed' >&2; exit 1
fi
[[ ! -e "$TEST_ROOT/publication/manifest.json.sig" ]]
gpgv --keyring "$TEST_ROOT/publication/signing-key.gpg" \
  "$TEST_ROOT/publication/signatures/$PACKAGE.sig" "$TEST_ROOT/publication/packages/$PACKAGE" > /dev/null 2>&1

rm -f "$TEST_ROOT/publication/manifest.json"
if run_signer; then
  echo 'FAIL: archive without manifest was signed' >&2; exit 1
fi
[[ ! -e "$TEST_ROOT/publication/manifest.json.sig" ]]
rm -f "$TEST_ROOT/output/$PACKAGE"
run_signer
[[ ! -e "$TEST_ROOT/publication/manifest.json.sig" ]]
echo 'PASS: sealed copies and signatures verify; changed or unapproved archives fail closed'
