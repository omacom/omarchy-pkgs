#!/bin/bash
# Validate the host-owned handoff, optionally before it has been signed.
set -euo pipefail

ARCH=${ARCH:-x86_64}
MIRROR=${MIRROR:-edge}
PUBLICATION_DIR=${PUBLICATION_DIR:-/publication}
HELPERS_DIR=${HELPERS_DIR:-/helpers}
PKGBUILDS_DIR=${PKGBUILDS_DIR:-/pkgbuilds}
directory="$PUBLICATION_DIR/packages"
unsigned=false
case ${1:-} in
  --unsigned) unsigned=true; directory="/build-output/$MIRROR/$ARCH" ;;
  '') ;;
  *) echo "Usage: verify-publication.sh [--unsigned]" >&2; exit 2 ;;
esac

files=$(python3 "$HELPERS_DIR/package-scope.py" verify --policy-root "$PKGBUILDS_DIR" \
  --arch "$ARCH" --directory "$directory" --manifest "$PUBLICATION_DIR/manifest.json")

if [[ $unsigned != true ]]; then
  keyring=$(mktemp -d)
  trap 'rm -rf -- "${keyring:?}"' EXIT
  gpgv --homedir "$keyring" --keyring "$PUBLICATION_DIR/signing-key.gpg" \
    -- "$PUBLICATION_DIR/manifest.json.sig" "$PUBLICATION_DIR/manifest.json"
  while IFS= read -r filename; do
    gpgv --homedir "$keyring" --keyring "$PUBLICATION_DIR/signing-key.gpg" \
      -- "$PUBLICATION_DIR/signatures/$filename.sig" "$directory/$filename"
  done <<< "$files"
fi

printf '%s\n' "$files"
