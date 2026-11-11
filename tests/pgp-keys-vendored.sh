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

missing=""
for pkgdir in "$ROOT"/pkgbuilds/*/; do
  shipped=$(cat "$pkgdir"/keys/pgp/*.asc 2>/dev/null |
    gpg --show-keys --with-colons 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }') || true
  for key in $(cd "$pkgdir" && bash -c 'source ./PKGBUILD >/dev/null 2>&1; echo "${validpgpkeys[@]}"' 2>/dev/null); do
    grep -qix -- "$key" <<<"$shipped" || missing+="  $(basename "$pkgdir"): $key"$'\n'
  done
done

if [[ -n $missing ]]; then
  printf 'FAIL: recipes trust keys they do not ship in keys/pgp/:\n%s' "$missing"
  exit 1
fi
echo "PASS: every validpgpkeys entry ships in its recipe's keys/pgp/"
