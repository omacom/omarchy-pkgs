# Common path variables for Omarchy package build system
# This file should be sourced after setting BUILD_ROOT

# Default architecture and mirror
ARCH=${ARCH:-x86_64}
MIRROR=${MIRROR:-edge}

# Architectures the tooling knows how to build.
VALID_ARCHES="x86_64 aarch64"

# Architectures this repository PUBLISHES. The scheduled pipeline (version
# check, auto-release, channel advance with --arch all) runs once per entry,
# in this order; the first entry is the reference architecture that the
# release train observes channels through. Adding an architecture here is the
# enablement step: the next check-versions tick queues its packages and the
# next auto-release tick builds them. OMARCHY_ARCHES overrides it for a
# one-off run.
PUBLISHED_ARCHES="${OMARCHY_ARCHES:-x86_64}"

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

published_arches() {
  local arch
  for arch in $PUBLISHED_ARCHES; do
    require_valid_arch "$arch"
    echo "$arch"
  done
}

reference_arch() {
  published_arches | head -1
}

# Scheduled-pipeline state, one file per channel and architecture, so one
# architecture's queue or backoff never gates another's.
STATE_DIR="${OMARCHY_STATE_DIR:-/root/.state}"

sync_queue_file() { # sync_queue_file <mirror> <arch>
  echo "$STATE_DIR/.sync-needed-$1-$2"
}

sync_fail_file() { # sync_fail_file <mirror> <arch>
  echo "$STATE_DIR/.build-failed-$1-$2"
}

# The pre-architecture names, .sync-needed-<mirror> and .build-failed-<mirror>,
# meant x86_64. A host upgraded mid-cycle may still hold one; readers treat
# it as the x86_64 file until it is consumed.
legacy_sync_queue_file() { echo "$STATE_DIR/.sync-needed-$1"; }
legacy_sync_fail_file() { echo "$STATE_DIR/.build-failed-$1"; }

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
LOG_DIR="$BUILD_ROOT/logs"
PKGBUILDS_DIR="$BUILD_ROOT/pkgbuilds"

# The published repository tree. Secondary checkouts (like the rc branch
# worktree on the build host) set OMARCHY_REPO_ROOT so every channel lives in
# one shared tree regardless of which checkout ran the command.
REPO_ROOT="${OMARCHY_REPO_ROOT:-$BUILD_ROOT/pkgs.omarchy.org}"

# Function to update architecture and mirror-specific paths
# Call this after changing ARCH or MIRROR variables
update_arch_paths() {
  BUILD_OUTPUT_DIR="$BUILD_ROOT/build-output/$MIRROR/$ARCH" # Unsigned packages
  REPO_DIR="$REPO_ROOT/$MIRROR/$ARCH"                       # Repository (signed packages)
}

# Initialize architecture-specific directories with default ARCH and MIRROR
update_arch_paths
