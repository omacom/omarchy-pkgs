#!/bin/bash
# Verify the host-approved publication manifest, then sign sealed package copies.
set -euo pipefail

: "${ARCH:?}"
: "${MIRROR:?}"
: "${PUBLICATION_DIR:?}"
: "${PKGBUILDS_DIR:?}"
: "${HELPERS_DIR:?}"

BUILD_OUTPUT_DIR="/build-output/$MIRROR/$ARCH"
MANIFEST="$PUBLICATION_DIR/manifest.json"
SCOPE="$HELPERS_DIR/package-scope.py"

# A prior commit signature must never survive a failed or incomplete signing run.
rm -f -- "$PUBLICATION_DIR/manifest.json.sig"

shopt -s nullglob
archives=("$BUILD_OUTPUT_DIR"/*.pkg.tar.zst)
if [[ ! -e $MANIFEST ]]; then
  if (( ${#archives[@]} == 0 )); then
    echo "==> No packages found to sign"
    exit 0
  fi
  echo "ERROR: Publication manifest missing for package archives" >&2
  exit 1
fi

[[ -f $MANIFEST && ! -L $MANIFEST ]] || { echo "ERROR: Invalid publication manifest" >&2; exit 1; }
[[ -d $BUILD_OUTPUT_DIR && -f $SCOPE ]] || { echo "ERROR: Signing inputs missing" >&2; exit 1; }

snapshot=$(mktemp -d)
staging=$(mktemp -d "$PUBLICATION_DIR/.sign.XXXXXXXX")
cleanup() {
  rm -rf -- "$snapshot" "$staging"
}
trap cleanup EXIT

# Capture the helper's exit status before reading its authorized filename list.
if ! python3 "$SCOPE" verify --policy-root "$PKGBUILDS_DIR" --arch "$ARCH" \
    --directory "$BUILD_OUTPUT_DIR" --manifest "$MANIFEST" > "$snapshot/files"; then
  echo "ERROR: Package scope verification failed" >&2
  exit 1
fi
mapfile -t packages < "$snapshot/files"
(( ${#packages[@]} > 0 )) || { echo "ERROR: Empty publication manifest" >&2; exit 1; }

cp -P -- "$MANIFEST" "$snapshot/manifest.json"
for package in "${packages[@]}"; do
  cp -P -- "$BUILD_OUTPUT_DIR/$package" "$snapshot/$package"
done

# Recheck copied bytes and identities. GPG sees only signer-owned copies.
if ! python3 "$SCOPE" verify --policy-root "$PKGBUILDS_DIR" --arch "$ARCH" \
    --directory "$snapshot" --manifest "$snapshot/manifest.json" > /dev/null; then
  echo "ERROR: Package snapshot verification failed" >&2
  exit 1
fi

mkdir -m 700 "$staging/packages" "$staging/signatures"
for package in "${packages[@]}"; do
  cp -P -- "$snapshot/$package" "$staging/packages/$package"
done
if ! python3 "$SCOPE" verify --policy-root "$PKGBUILDS_DIR" --arch "$ARCH" \
    --directory "$staging/packages" --manifest "$snapshot/manifest.json" > /dev/null; then
  echo "ERROR: Sealed package verification failed" >&2
  exit 1
fi

: "${GPG_PRIVATE_KEY:?GPG_PRIVATE_KEY environment variable not set}"
GPG_PASSPHRASE=${GPG_PASSPHRASE-}
export GNUPGHOME="$snapshot/gnupg"
mkdir -m 700 "$GNUPGHOME"
printf '%s' "$GPG_PRIVATE_KEY" | gpg --batch --quiet --import 2>/dev/null || {
  echo "ERROR: Failed to import signing key" >&2
  exit 1
}
if ! gpg --batch --with-colons --list-secret-keys 2>/dev/null | \
    awk -F: '$1 == "sec" { primary = 1; next } primary && $1 == "fpr" { print $10; primary = 0 }' > "$snapshot/fingerprints"; then
  echo "ERROR: Failed to list signing key" >&2
  exit 1
fi
mapfile -t fingerprints < "$snapshot/fingerprints"
(( ${#fingerprints[@]} == 1 )) || { echo "ERROR: Expected one signing key" >&2; exit 1; }
fingerprint=${fingerprints[0]}

sign_file() {
  local input=$1 output=$2
  gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 \
    --local-user "$fingerprint" --output "$output" --detach-sign "$input" \
    3<<<"$GPG_PASSPHRASE"
}

for package in "${packages[@]}"; do
  sign_file "$staging/packages/$package" "$staging/signatures/$package.sig"
done
gpg --batch --quiet --export "$fingerprint" > "$staging/signing-key.gpg"
[[ -s $staging/signing-key.gpg ]] || { echo "ERROR: Signing key export failed" >&2; exit 1; }
sign_file "$snapshot/manifest.json" "$staging/manifest.json.sig"

# Replace the previous handoff while its commit marker is absent.
for directory in packages signatures; do
  if [[ -e $PUBLICATION_DIR/$directory ]]; then
    mv -T -- "$PUBLICATION_DIR/$directory" "$staging/old-$directory"
  fi
  mv -T -- "$staging/$directory" "$PUBLICATION_DIR/$directory"
done
mv -f -- "$staging/signing-key.gpg" "$PUBLICATION_DIR/signing-key.gpg"
# The manifest signature is the handoff commit marker and must be written last.
mv -f -- "$staging/manifest.json.sig" "$PUBLICATION_DIR/manifest.json.sig"
echo "==> Signed ${#packages[@]} package(s) and publication manifest"
