#!/bin/bash
# Every key a recipe trusts ships with it in keys/pgp/. A build never asks a
# keyserver: on 11 November 2026 keyserver.ubuntu.com stopped answering, each
# build waited on gpg --receive-keys with no timeout, and stuck builds held
# every builder for hours.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
GNUPGHOME=$(mktemp -d)
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT

# The primary-key fingerprints a key file holds, one per line.
primaries() {
  gpg --show-keys --with-colons "$1" 2>/dev/null |
    awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }'
}

problems=""
for pkgdir in "$ROOT"/pkgbuilds/*/; do
  pkg=$(basename "$pkgdir")
  # bin/refresh-pgp-keys reads the fingerprint from the file name, so each
  # file must be <FINGERPRINT>.asc and hold that one primary key.
  for file in "$pkgdir"keys/pgp/*.asc; do
    [[ -e $file ]] || continue
    name=$(basename "$file" .asc)
    [[ $(primaries "$file") == "$name" ]] ||
      problems+="  $pkg: keys/pgp/$name.asc must hold exactly the primary key $name"$'\n'
  done
  for key in $(cd "$pkgdir" && bash -c 'source ./PKGBUILD >/dev/null 2>&1; echo "${validpgpkeys[@]}"' 2>/dev/null); do
    [[ -f $pkgdir/keys/pgp/$key.asc ]] ||
      problems+="  $pkg: validpgpkeys $key has no keys/pgp/$key.asc"$'\n'
  done
done

if [[ -n $problems ]]; then
  printf 'FAIL: shipped signing keys:\n%s' "$problems"
  exit 1
fi
echo "PASS: every validpgpkeys entry ships as keys/pgp/<FINGERPRINT>.asc holding that key"
