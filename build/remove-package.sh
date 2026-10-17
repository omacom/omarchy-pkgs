#!/bin/bash
# Remove package from repository (runs inside Docker)

set -e

ARCH=${ARCH:-x86_64}
MIRROR=${MIRROR:-edge}
PACKAGE_NAME="$1"
REPO_DIR="/pkgs.omarchy.org/$MIRROR/$ARCH"

if [[ -z "$PACKAGE_NAME" ]]; then
  echo "ERROR: Package name required"
  exit 1
fi

cd "$REPO_DIR"

# Find exact package files (not subpackages like yay-debug)
FILES=$(ls ${PACKAGE_NAME}-[0-9]*.pkg.tar.* 2>/dev/null || true)

if [[ -z "$FILES" ]]; then
  echo "ERROR: Package '$PACKAGE_NAME' not found"
  exit 1
fi

echo "==> Removing package: $PACKAGE_NAME"
echo ""
echo "Files to remove:"
for file in $FILES; do
  echo "  - $file"
done
echo ""

# Remove from database
echo "==> Removing from repository database..."
repo-remove omarchy.db.tar.zst "$PACKAGE_NAME"

# Remove files
echo "==> Removing package files..."
for file in $FILES; do
  rm -f "$file"
  echo "  ✓ Removed $file"
done

echo ""
echo "==> Package '$PACKAGE_NAME' removed successfully"
