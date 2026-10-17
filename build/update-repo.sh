#!/bin/bash
# Repository database update script (runs inside Docker container)

set -e

ARCH=${ARCH:-x86_64}
MIRROR=${MIRROR:-edge}
OUTPUT_DIR="/output/$MIRROR/$ARCH"
REPO_NAME="omarchy"
DB_FILE="$OUTPUT_DIR/${REPO_NAME}.db.tar.zst"

cd "$OUTPUT_DIR"

# Remove old database files (repo-add will create new ones)
rm -f "${REPO_NAME}.db" "${REPO_NAME}.db.tar.zst"
rm -f "${REPO_NAME}.files" "${REPO_NAME}.files.tar.zst"

# Check if there are any packages
if ! ls *.pkg.tar.* 1>/dev/null 2>&1; then
  echo "==> No packages found in $OUTPUT_DIR"
  echo "==> Run bin/repo build first to build packages"
  exit 1
fi

# Add all packages to the database (only latest version of each)
echo "==> Adding packages to database..."

# Build list of latest packages using vercmp for proper version sorting
declare -A latest_pkgs
declare -A latest_vers

# Helper to extract pkgname and version from filename
# Uses bsdtar to read .PKGINFO for accurate info
get_pkg_info() {
  local pkg="$1"
  bsdtar -xOqf "$pkg" .PKGINFO 2>/dev/null | awk '
    /^pkgname = / { name = substr($0, 11) }
    /^pkgver = / { ver = substr($0, 10) }
    END { print name " " ver }
  '
}

for pkg in *.pkg.tar.*; do
  [[ "$pkg" == *.sig ]] && continue
  [[ ! -f "$pkg" ]] && continue
  
  read -r name ver <<< "$(get_pkg_info "$pkg")"
  [[ -z "$name" ]] && continue
  
  if [[ -z "${latest_pkgs[$name]}" ]]; then
    latest_pkgs[$name]="$pkg"
    latest_vers[$name]="$ver"
  else
    if [[ $(vercmp "$ver" "${latest_vers[$name]}") -gt 0 ]]; then
      latest_pkgs[$name]="$pkg"
      latest_vers[$name]="$ver"
    fi
  fi
done

# Add latest packages to repo
for pkg in "${latest_pkgs[@]}"; do
  echo "  Adding: $pkg"
done | sort

repo-add "$DB_FILE" "${latest_pkgs[@]}" || {
  echo "==> Failed to update repository database"
  exit 1
}

# Create symlinks for compatibility
ln -sf "${REPO_NAME}.db.tar.zst" "${REPO_NAME}.db"
ln -sf "${REPO_NAME}.files.tar.zst" "${REPO_NAME}.files"

# Count packages
PACKAGE_COUNT=$(ls -1 *.pkg.tar.* 2>/dev/null | grep -v '\.sig$' | wc -l)

echo "==> Database updated successfully!"
echo "==> Total packages in repository: $PACKAGE_COUNT"

# List packages in database
echo "==> Packages in database:"
tar -tf "$DB_FILE" 2>/dev/null | grep -E "^[^/]+/$" | sed 's|/$||' | sort -u | while read -r pkg; do
  echo "  - $pkg"
done
