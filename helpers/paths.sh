# Common path variables for Omarchy package build system
# This file should be sourced after setting BUILD_ROOT

# Default architecture and mirror
ARCH=${ARCH:-x86_64}
MIRROR=${MIRROR:-edge}

# Architectures the tooling knows how to build.
VALID_ARCHES="x86_64 aarch64"

validate_arch() {
  case " $VALID_ARCHES " in
  *" $1 "*) return 0 ;;
  *) return 1 ;;
  esac
}

require_valid_arch() {
  if ! validate_arch "$1"; then
    echo "Invalid architecture: $1 (must be one of: $VALID_ARCHES)" >&2
    exit 1
  fi
}

# Architectures CI builds and publishes: bin/build-matrix plans a PR build for
# each one a package supports, publish.yml ships them, and anything deciding
# what a merge has to rebuild (bin/sync-rebuilds) or whether a channel holds a
# version (bin/omarchy-release) follows this list. CI_ARCHES overrides it.
CI_ARCHES="${CI_ARCHES:-x86_64 aarch64}"

ci_arches() {
  local arch
  for arch in $CI_ARCHES; do
    require_valid_arch "$arch"
    echo "$arch"
  done
}

# The first CI architecture: the one the release train reads channels through
# when one architecture's answer stands for both.
reference_arch() {
  ci_arches | head -1
}

# Valid package channels, in pipeline order: packages move edge -> rc -> stable
VALID_MIRRORS="edge rc stable"

validate_mirror() {
  case "$1" in
  edge | rc | stable) return 0 ;;
  *) return 1 ;;
  esac
}

require_valid_mirror() {
  if ! validate_mirror "$1"; then
    echo "Invalid mirror: $1 (must be one of: $VALID_MIRRORS)" >&2
    exit 1
  fi
}

# Core directories (architecture-independent)
BUILD_DIR="$BUILD_ROOT/build"
SRC_DIR="$BUILD_ROOT/src"
PKGBUILDS_DIR="$BUILD_ROOT/pkgbuilds"

# A local copy of a channel, mounted into the build container. bin/build
# creates it empty; with no local database, build/build.sh plans against the
# channel's published database instead.
REPO_ROOT="$BUILD_ROOT/pkgs.omarchy.org"

# Function to update architecture and mirror-specific paths
# Call this after changing ARCH or MIRROR variables
update_arch_paths() {
  BUILD_OUTPUT_DIR="$BUILD_ROOT/build-output/$MIRROR/$ARCH" # Unsigned packages
  REPO_DIR="$REPO_ROOT/$MIRROR/$ARCH"                       # Local channel copy (empty in CI)
}

# Initialize architecture-specific directories with default ARCH and MIRROR
update_arch_paths
