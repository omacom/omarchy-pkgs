#!/bin/bash
# Sign packages in build-output (runs inside Docker)

set -e

ARCH=${ARCH:-x86_64}
MIRROR=${MIRROR:-edge}
BUILD_OUTPUT_DIR="/build-output/$MIRROR/$ARCH"

echo "==> Package Signing"
echo "==> Target architecture: $ARCH"
echo "==> Mirror: $MIRROR"
echo "==> Build output: $BUILD_OUTPUT_DIR"

# Check if GPG key and passphrase are provided
if [[ -z "$GPG_PRIVATE_KEY" ]]; then
  echo "ERROR: GPG_PRIVATE_KEY environment variable not set"
  exit 1
fi

if [[ -z "$GPG_PASSPHRASE" ]]; then
  echo "ERROR: GPG_PASSPHRASE environment variable not set"
  exit 1
fi

# Import GPG key
echo "==> Importing GPG signing key..."
echo "$GPG_PRIVATE_KEY" | gpg --batch --import 2>/dev/null || {
  echo "ERROR: Failed to import signing key"
  exit 1
}

# Get key ID
KEY_ID=$(gpg --list-secret-keys --keyid-format LONG 2>/dev/null | grep "sec" | head -1 | awk '{print $2}' | cut -d'/' -f2)

if [[ -z "$KEY_ID" ]]; then
  echo "ERROR: Could not extract key ID"
  exit 1
fi

echo "  ✓ GPG signing key loaded: $KEY_ID"

# Check if build output exists and has packages
if [[ ! -d "$BUILD_OUTPUT_DIR" ]]; then
  echo "ERROR: Build output directory not found: $BUILD_OUTPUT_DIR"
  exit 1
fi

cd "$BUILD_OUTPUT_DIR"

# Find all unsigned package files
PACKAGE_FILES=$(ls -1 *.pkg.tar.zst 2>/dev/null || true)

if [[ -z "$PACKAGE_FILES" ]]; then
  echo "==> No packages found to sign"
  exit 0
fi

PACKAGE_COUNT=$(echo "$PACKAGE_FILES" | wc -l)
echo "==> Found $PACKAGE_COUNT package(s) to sign"
echo ""

# Sign all packages
SIGNED_COUNT=0
FAILED_COUNT=0

for pkg_file in $PACKAGE_FILES; do
  echo -n "  -> $pkg_file ... "
  
  # Remove existing signature if present
  rm -f "$pkg_file.sig"
  
  # Sign the package
  if gpg --batch --yes --pinentry-mode loopback --passphrase "$GPG_PASSPHRASE" \
    --detach-sign --use-agent --no-armor --local-user "$KEY_ID" "$pkg_file" 2>/dev/null; then
    echo "✓"
    SIGNED_COUNT=$((SIGNED_COUNT + 1))
  else
    echo "✗"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
done

echo ""

# Summary
if [[ $FAILED_COUNT -eq 0 ]]; then
  echo "==> Successfully signed all $SIGNED_COUNT package(s)"
  exit 0
else
  echo "==> Signed $SIGNED_COUNT package(s), failed $FAILED_COUNT"
  exit 1
fi
