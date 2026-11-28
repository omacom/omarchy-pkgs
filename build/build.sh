#!/bin/bash
# Plan a run or build one planned package in an isolated container.
# Unscoped edge builds exclude skip_build packages. Stable also requires the fast release ring.
# Explicit --package selections may build packages with skip_build=true.

# Setup directories
ARCH=${ARCH:-x86_64}
# ARCH selects the repository target for this script, but make and Kbuild also
# interpret an exported ARCH themselves (Linux calls this target "arm64").
# Keep the shell variable local to the orchestrator so PKGBUILDs see CARCH only.
export -n ARCH
# The architecture this container runs. It differs from ARCH only for a
# package that cross-compiles (package_build_host); bin/build sets both. A
# dry run plans for every builder and passes "any".
BUILDER_ARCH=${BUILDER_ARCH:-$ARCH}
MIRROR=${MIRROR:-edge}
DRY_RUN=${DRY_RUN:-false}
# bin/build plans the whole run, then invokes this script once per package in
# a fresh container. PACKAGES retains the original request for validation.
BUILD_PACKAGE=${BUILD_PACKAGE:-}
BUILD_PLAN_DIR=${BUILD_PLAN_DIR:-}
PKGBUILDS_DIR=${PKGBUILDS_DIR:-/pkgbuilds}
BUILD_OUTPUT_DIR=${BUILD_OUTPUT_DIR:-/build-output/$MIRROR/$ARCH}
FINAL_OUTPUT_DIR=${FINAL_OUTPUT_DIR:-/pkgs.omarchy.org/$MIRROR/$ARCH}
HELPERS_DIR=${HELPERS_DIR:-/helpers}
SRC_DIR=${SRC_DIR:-/src}
# Set by bin/build from OMARCHY_DEFER_RUNTIME_DEPS after it has checked the
# request; re-checked here so the container never trusts a stray value.
DEFER_RUNTIME_DEPS=${DEFER_RUNTIME_DEPS:-false}

source "$HELPERS_DIR/package-metadata.sh"
source "$HELPERS_DIR/package-owners.sh"

# Where the channel's published database is read from for planning: a local
# copy when one is mounted (the build-plan test uses one), otherwise the public
# channel, whose URL then also serves as pacman's dependency repository.
# Set OMARCHY_PUBLISHED_REPO_URL= (empty) to disable the remote fallback.
PUBLISHED_REPO_URL=${OMARCHY_PUBLISHED_REPO_URL-https://pkgs.omarchy.org}
PUBLISHED_DB_DIR="$FINAL_OUTPUT_DIR"
PUBLISHED_REPO_SERVER=""
if [[ ! -f "$FINAL_OUTPUT_DIR/omarchy.db.tar.zst" && ! -f "$FINAL_OUTPUT_DIR/omarchy.db" && -n "$PUBLISHED_REPO_URL" ]]; then
  remote_channel="$PUBLISHED_REPO_URL/$MIRROR/$ARCH"
  remote_db_dir=$(mktemp -d /tmp/omarchy-published.XXXXXX) || exit 1
  # Cache-bust: the channel sits behind a CDN that serves a stale database
  # for a while after a sync.
  if curl -fsSL "$remote_channel/omarchy.db.tar.zst?$(date +%s)" -o "$remote_db_dir/omarchy.db.tar.zst"; then
    PUBLISHED_DB_DIR="$remote_db_dir"
    PUBLISHED_REPO_SERVER="$remote_channel"
    echo "==> No local published tree; planning against $remote_channel"
  else
    rm -rf "$remote_db_dir"
    echo "==> No local published tree and $remote_channel is unavailable; treating the channel as empty"
  fi
fi

if [[ $DEFER_RUNTIME_DEPS != "false" && $DEFER_RUNTIME_DEPS != "true" ]]; then
  echo "DEFER_RUNTIME_DEPS must be true or false" >&2
  exit 1
fi
if [[ $DEFER_RUNTIME_DEPS == "true" ]]; then
  deferred_runtime=0
  deferred_settings=0
  deferred_count=0
  for package in $PACKAGES; do
    ((deferred_count += 1))
    case $package in
      omarchy|omarchy-dev) deferred_runtime=1 ;;
      omarchy-settings|omarchy-settings-dev) deferred_settings=1 ;;
      *)
        echo "Runtime dependency deferral only applies to the omarchy pair, not $package" >&2
        exit 1
        ;;
    esac
  done
  if (( deferred_runtime != 1 || deferred_settings != 1 || deferred_count != 2 )); then
    echo "Runtime dependency deferral requires exactly the omarchy pair" >&2
    exit 1
  fi
fi

if [[ "$DRY_RUN" != true ]]; then
  if [[ -z "$BUILD_PACKAGE" || -z "$BUILD_PLAN_DIR" ]]; then
    echo "Use bin/build to plan and run isolated package builds" >&2
    exit 1
  fi
  if ! grep -Fxq -- "$BUILD_PACKAGE" "$BUILD_PLAN_DIR/packages"; then
    echo "Package is not in the build plan: $BUILD_PACKAGE" >&2
    exit 1
  fi

  mkdir -p "$BUILD_OUTPUT_DIR" "$FINAL_OUTPUT_DIR"

  # The image drops pacman's private signing key. Keyring upgrades need a
  # container-local key to sign newly trusted keys.
  sudo pacman-key --init || exit 1

  # Bring the container up to date before any makedepends are installed. The
  # image is layer-cached, so its glibc drifts behind the mirror while makepkg
  # -s pulls makedepends from the freshly synced database -- a partial upgrade
  # that breaks the new packages (imagemagick wanting GLIBC_2.44, etc).
  # Done before the Omarchy repos are added so only core/extra participate.
  echo "==> Updating build container packages..."
  sudo pacman -Syu --noconfirm || exit 1

  # Configure Omarchy repositories for dependency resolution
  echo "==> Configuring Omarchy repositories for dependency resolution..."

  # Always add omarchy-build repo first (for incremental builds). Repository
  # order is pacman's priority order, so this must precede the official repos;
  # otherwise pacman can select an older official package with the same name.
  # Packages in build-output are unsigned, so use SigLevel = Never. A cross
  # build keeps the database for its outputs, but its $ARCH packages cannot
  # run in this container, so pacman never installs from it.
  if [[ $BUILDER_ARCH == "$ARCH" ]]; then
    sudo sed -i "/^\[core\]$/i [omarchy-build]\nSigLevel = Never\nServer = file://$BUILD_OUTPUT_DIR\n" /etc/pacman.conf
    echo "  -> omarchy-build (priority 1): $BUILD_OUTPUT_DIR"
  fi

  # Initialize empty build database if it doesn't exist
  cd "$BUILD_OUTPUT_DIR" || exit 1
  if [[ ! -f "omarchy-build.db.tar.zst" ]]; then
    # Create an empty database
    repo-add omarchy-build.db.tar.zst >/dev/null 2>&1 || exit 1
    ln -sf omarchy-build.db.tar.zst omarchy-build.db || exit 1
  fi
  # Fold any packages already in the workspace into the database, whether
  # they came with an existing database or were dropped in by an earlier
  # workflow job (OMARCHY_KEEP_BUILD_WORKSPACE). Without this a seeded
  # workspace with no database would leave those packages invisible to
  # dependency resolution.
  staged_packages=()
  for staged in *.pkg.tar.*; do
    [[ -f "$staged" && "$staged" != *.sig ]] || continue
    staged_packages+=("$staged")
  done
  if (( ${#staged_packages[@]} )); then
    # Seed once per run. After that, only successful builds update the DB;
    # rescanning in every container could reintroduce a failed build's partial
    # outputs or overwrite the new version with an older kept artifact.
    if [[ ! -e "$BUILD_PLAN_DIR/repository-initialized" ]]; then
      echo "==> Rebuilding build database from existing packages..."
      # --prevent-downgrade ensures alphabetical glob order (e.g. 1.10-1 before
      # 1.9-1, or 1:1.0-1 before 2.0-1) cannot replace a newer archive with an
      # older one in the build database.
      repo-add --prevent-downgrade omarchy-build.db.tar.zst "${staged_packages[@]}" >/dev/null 2>&1 || exit 1
      ln -sf omarchy-build.db.tar.zst omarchy-build.db || exit 1
    fi
    # A resumed/repeated build can produce different bytes under the same
    # filename. Never let the shared download cache substitute older bytes
    # for the staged artifacts described by this run's database.
    for staged in "${staged_packages[@]}"; do
      sudo rm -f "/var/cache/pacman/pkg/$staged" "/var/cache/pacman/pkg/$staged.sig" || exit 1
    done
  fi
  touch "$BUILD_PLAN_DIR/repository-initialized" || exit 1

  # Add omarchy repo if it has a database (stable packages). The local tree
  # is trusted as-is; the public channel is verified against the omarchy
  # keyring the image already carries. A cross build installs only packages
  # that run here, so it takes Omarchy's tree or channel for the builder's
  # architecture, found the same way.
  if [[ $BUILDER_ARCH != "$ARCH" ]]; then
    builder_tree="${FINAL_OUTPUT_DIR%/*}/$BUILDER_ARCH"
    builder_channel="$PUBLISHED_REPO_URL/$MIRROR/$BUILDER_ARCH"
    if [[ -f "$builder_tree/omarchy.db.tar.zst" ]] || [[ -f "$builder_tree/omarchy.db" ]]; then
      sudo sed -i "/^\[core\]$/i [omarchy]\nSigLevel = Optional TrustAll\nServer = file://$builder_tree\n" /etc/pacman.conf
      echo "  -> omarchy (priority 2): $builder_tree"
    elif [[ -n "$PUBLISHED_REPO_URL" ]] && curl -fsI --max-time 30 "$builder_channel/omarchy.db.tar.zst" >/dev/null; then
      sudo sed -i "/^\[core\]$/i [omarchy]\nSigLevel = Required DatabaseOptional\nServer = $builder_channel\n" /etc/pacman.conf
      echo "  -> omarchy (priority 2): $builder_channel"
    fi
  elif [[ -f "$FINAL_OUTPUT_DIR/omarchy.db.tar.zst" ]] || [[ -f "$FINAL_OUTPUT_DIR/omarchy.db" ]]; then
    sudo sed -i "/^\[core\]$/i [omarchy]\nSigLevel = Optional TrustAll\nServer = file://$FINAL_OUTPUT_DIR\n" /etc/pacman.conf
    echo "  -> omarchy (priority 2): $FINAL_OUTPUT_DIR"
  elif [[ -n "$PUBLISHED_REPO_SERVER" ]]; then
    sudo sed -i "/^\[core\]$/i [omarchy]\nSigLevel = Required DatabaseOptional\nServer = $PUBLISHED_REPO_SERVER\n" /etc/pacman.conf
    echo "  -> omarchy (priority 2): $PUBLISHED_REPO_SERVER"
  fi

  # Sync pacman database
  sudo pacman -Sy || exit 1

  # A cross build: makepkg names and checks packages for ARCH. Its strip
  # step runs this image's GNU strip, which reads only $BUILDER_ARCH objects,
  # so it is off; a cross recipe strips with its own toolchain. makepkg -s
  # still installs the recipe's depends, in their $BUILDER_ARCH builds: host
  # tools the build runs link them (V8's snapshot generator needs libxcb).
  if [[ $BUILDER_ARCH != "$ARCH" ]]; then
    echo "==> Cross-building for $ARCH on $BUILDER_ARCH"
    sed -e "s/^CARCH=.*/CARCH=\"$ARCH\"/" -e "s/^CHOST=.*/CHOST=\"$ARCH-unknown-linux-gnu\"/" \
      -e "/^OPTIONS=/s/\([( ]\)strip/\1!strip/" /etc/makepkg.conf > "/tmp/makepkg-$ARCH.conf" || exit 1
    grep -q '^OPTIONS=(.*!strip' "/tmp/makepkg-$ARCH.conf" || exit 1
    export MAKEPKG_CONF="/tmp/makepkg-$ARCH.conf"
  fi
fi

echo "==> Package Builder"
echo "==> Target architecture: $ARCH"
echo "==> Mirror: $MIRROR"
echo "==> Package root: $PKGBUILDS_DIR"
echo "==> Build workspace: $BUILD_OUTPUT_DIR"
echo "==> Final output: $FINAL_OUTPUT_DIR"
if [[ "$DRY_RUN" == true ]]; then
  echo "==> Dry run: yes (plan only; makepkg will not run)"
fi

SKIPPED_PACKAGES=""

# Find package directory
find_package_dir() {
  local pkg="$1"
  package_dir_for_name "$pkg"
}

# Read a PKGBUILD's makepkg full version (epoch:pkgver-pkgrel when epoch > 0,
# else pkgver-pkgrel) with CARCH set and OMARCHY_SRC unset. Fails if sourcing
# fails, pkgver/pkgrel is empty, or epoch is not a non-negative integer.
read_pkgbuild_version() {
  local pkgdir="$1"
  (
    cd "$pkgdir" && env -u OMARCHY_SRC CARCH="$ARCH" bash -c '
      source ./PKGBUILD >/dev/null 2>&1 || exit 1
      [[ -n "${pkgver:-}" && -n "${pkgrel:-}" ]] || exit 1
      if [[ -n "${epoch:-}" ]]; then
        [[ "$epoch" =~ ^[0-9]+$ ]] || exit 1
        if (( 10#$epoch > 0 )); then
          printf "%s:%s-%s\n" "$epoch" "$pkgver" "$pkgrel"
          exit 0
        fi
      fi
      printf "%s-%s\n" "$pkgver" "$pkgrel"
    '
  )
}

# Read the pkgname array from a PKGBUILD with CARCH set and OMARCHY_SRC unset.
read_pkgbuild_pkgnames() {
  local pkgdir="$1"
  (
    cd "$pkgdir" && env -u OMARCHY_SRC CARCH="$ARCH" bash -c '
      source ./PKGBUILD >/dev/null 2>&1 || exit 1
      (( ${#pkgname[@]} )) || exit 1
      for name in "${pkgname[@]}"; do
        [[ -n "$name" ]] || exit 1
        printf "%s\n" "$name"
      done
    '
  )
}

# Extract the recorded VCS commit hash component from a pacman version string
# (preserving its full recorded length, 7..40 chars). Recognizes g<hex>, bare
# hex containing [a-f], or a trailing all-digit hash component (e.g. r100.1234567)
# without mistaking a leading revision count (e.g. r12345678) for a commit hash.
extract_vcs_hash() {
  local ver="$1"
  local no_rel="${ver%-*}"
  [[ "$no_rel" == *:* ]] && no_rel="${no_rel#*:}"
  local token g_hash="" hex_hash="" last_token=""
  local -a tokens=()
  IFS='.+_' read -r -a tokens <<< "$no_rel"
  for token in "${tokens[@]}"; do
    last_token="$token"
    if [[ "$token" =~ g([a-f0-9]{7,40})$ ]]; then
      g_hash="${BASH_REMATCH[1]}"
    elif [[ "$token" =~ ^[a-f0-9]{7,40}$ && "$token" =~ [a-f] ]]; then
      hex_hash="$token"
    fi
  done
  if [[ -n "$g_hash" ]]; then
    printf '%s\n' "$g_hash"
  elif [[ -n "$hex_hash" ]]; then
    printf '%s\n' "$hex_hash"
  elif (( ${#tokens[@]} > 1 )) && [[ "$last_token" =~ ^[0-9]{7,40}$ ]]; then
    printf '%s\n' "$last_token"
  fi
}

# Return 0 if a pacman version's recorded commit hash matches the upstream hash
# prefix across every digit recorded in the package version.
version_matches_hash() {
  local ver="$1" upstream_hash="$2"
  [[ -n "$upstream_hash" ]] || return 1
  local recorded
  recorded=$(extract_vcs_hash "$ver")
  [[ -n "$recorded" && ( "$upstream_hash" == "$recorded"* || "$recorded" == "$upstream_hash"* ) ]]
}

# Get version from final output (production packages)
#
# Source package directories are named after the PKGBUILD pkgbase, but split
# packages are stored in the repo DB under their individual pkgname entries.
# Cache versions by both %NAME% and %BASE% so a pkgbase like
# libretro-vice-git can be found even though the DB only contains packages like
# libretro-vice-x64-git.
declare -A LOCAL_VERSION_BY_NAME=()
declare -A LOCAL_VERSION_BY_BASE=()
LOCAL_VERSION_CACHE_LOADED=false
LOCAL_VERSION_CACHE_DB=""

load_local_versions() {
  local db="$PUBLISHED_DB_DIR/omarchy.db.tar.zst"

  if [[ ! -f "$db" ]]; then
    db="$PUBLISHED_DB_DIR/omarchy.db"
  fi

  [[ -f "$db" ]] || return 0
  [[ "$LOCAL_VERSION_CACHE_LOADED" == true && "$LOCAL_VERSION_CACHE_DB" == "$db" ]] && return 0

  LOCAL_VERSION_BY_NAME=()
  LOCAL_VERSION_BY_BASE=()

  local name base version
  while IFS=$'\t' read -r name base version; do
    [[ -n "$name" && -n "$version" ]] && LOCAL_VERSION_BY_NAME["$name"]="$version"
    [[ -n "$base" && -n "$version" ]] && LOCAL_VERSION_BY_BASE["$base"]="$version"
  done < <(
    tar -xOf "$db" --wildcards '*/desc' 2>/dev/null | awk '
      function emit() {
        if (name != "" && version != "") print name "\t" base "\t" version
        name=""; base=""; version=""
      }
      $0 == "%FILENAME%" { emit(); next }
      $0 == "%NAME%" { if (name != "" && version != "") emit(); getline; name=$0; next }
      $0 == "%BASE%" { getline; base=$0; next }
      $0 == "%VERSION%" { getline; version=$0; next }
      END { emit() }
    '
  )

  LOCAL_VERSION_CACHE_LOADED=true
  LOCAL_VERSION_CACHE_DB="$db"
}

get_local_version() {
  local pkg="$1"

  load_local_versions

  if [[ -n "${LOCAL_VERSION_BY_NAME[$pkg]:-}" ]]; then
    echo "${LOCAL_VERSION_BY_NAME[$pkg]}"
  elif [[ -n "${LOCAL_VERSION_BY_BASE[$pkg]:-}" ]]; then
    echo "${LOCAL_VERSION_BY_BASE[$pkg]}"
  fi
}

# package_version_is_published for a plan read from the public channel: its
# retained archives are only reachable there, so a version the database no
# longer indexes (master's stable pin once edge indexes the next RC) would
# otherwise read as unpublished and be rebuilt. The four candidate names are
# asked in parallel: a HEAD is never cached at the edge, so each answer takes
# about 160 ms, and a version that needs building misses all four.
remote_published_pkgnames() {
  local version="$1"
  shift
  local package target ext url exitcode http_code url_req matched
  local -a requests=()
  local -A url_to_pkg=() seen=()
  [[ -n "$PUBLISHED_REPO_SERVER" ]] || return 0
  for package in "$@"; do
    for target in "$ARCH" any; do
      for ext in zst xz; do
        url="$PUBLISHED_REPO_SERVER/$package-$version-$target.pkg.tar.$ext"
        requests+=(-o /dev/null "$url")
        url_to_pkg["$url"]="$package"
      done
    done
  done
  (( ${#requests[@]} )) || return 0
  # What `curl -f` accepted when the names were tried in turn: the transfer
  # itself succeeded, and the status is below 400. All candidates are awaited,
  # so each gets a time limit: one name that never answers must not hold up an
  # archive another name already found.
  while read -r exitcode http_code url_req; do
    if [[ "$exitcode" == 0 ]] && (( http_code >= 200 && http_code < 400 )); then
      matched="${url_to_pkg[$url_req]:-}"
      if [[ -n "$matched" && -z "${seen[$matched]:-}" ]]; then
        seen["$matched"]=1
        printf '%s\n' "$matched"
      fi
    fi
  done < <(curl -sI --parallel --max-time 10 -w '%{exitcode} %{http_code} %{url}\n' "${requests[@]}")
}

# Check if package should be built for current architecture, in this
# builder: a package that cross-compiles builds only in its own builder image.
# Returns 0 (success) if should build, 1 if should skip
should_build_for_arch() {
  local pkg="$1"
  local pkgdir arches
  pkgdir=$(find_package_dir "$pkg") || return 1
  arches=$(package_arches "$pkgdir" "$ARCH") || return 2
  case " $arches " in
    *" any "* | *" $ARCH "*) builds_in_this_builder "$pkg" ;;
    *) return 1 ;;
  esac
}

builds_in_this_builder() {
  [[ $BUILDER_ARCH == any || $(package_build_host "$1" "$ARCH") == "$BUILDER_ARCH" ]]
}

# For VCS packages, makepkg recalculates pkgver() before the build. If the
# recalculated pkgver differs from the static PKGBUILD value, makepkg resets
# pkgrel to 1. That is right for stock VCS packages, but wrong for Omarchy's
# patched AUR packages where sync-aur intentionally applies a dotted local
# pkgrel suffix (for example 1.1) to sort above the upstream/AUR package.
# Refresh pkgver once, then restore the local dotted pkgrel before the real
# build so the produced package filename carries the Omarchy revision.
refresh_vcs_pkgver_preserving_local_pkgrel() {
  local pkg="$1"
  local pkgbuild="PKGBUILD"

  grep -qE '^pkgver[[:space:]]*\(\)' "$pkgbuild" || return 0

  local original_pkgver original_pkgrel refreshed_pkgver refreshed_pkgrel
  original_pkgver=$(package_pkgbuild_var "$PWD" pkgver "$ARCH") || return 1
  original_pkgrel=$(package_pkgbuild_var "$PWD" pkgrel "$ARCH") || return 1

  # Omarchy local rebuilds use dotted pkgrels (AUR pkgrel + .suffix). Plain
  # integer pkgrels can keep makepkg's normal reset-to-1 behavior on new VCS
  # revisions.
  [[ "$original_pkgrel" == *.* ]] || return 0

  echo "    Refreshing VCS pkgver before build (preserving local pkgrel=$original_pkgrel)..."
  if [[ -x /usr/local/bin/pacman-for-makepkg ]]; then
    PACMAN=/usr/local/bin/pacman-for-makepkg makepkg --nobuild --nodeps --skipinteg --skippgpcheck --noprepare --noconfirm
  else
    makepkg --nobuild --nodeps --skipinteg --skippgpcheck --noprepare --noconfirm
  fi

  if [[ $? -ne 0 ]]; then
    echo "    Failed to refresh VCS pkgver for $pkg"
    return 1
  fi

  refreshed_pkgver=$(package_pkgbuild_var "$PWD" pkgver "$ARCH") || return 1
  refreshed_pkgrel=$(package_pkgbuild_var "$PWD" pkgrel "$ARCH") || return 1

  if [[ "$refreshed_pkgrel" != "$original_pkgrel" ]]; then
    sed -i "s/^pkgrel=.*/pkgrel=$original_pkgrel/" PKGBUILD
    echo "    Restored local pkgrel suffix: $refreshed_pkgrel -> $original_pkgrel"
  fi

  if [[ -n "$refreshed_pkgver" && "$refreshed_pkgver" != "$original_pkgver" ]]; then
    echo "    Refreshed VCS version: $original_pkgver -> $refreshed_pkgver"
  fi
}

# With runtime dependency checks deferred, makepkg runs --nodeps, so the
# build-time dependencies it would normally install with -s have to be
# installed explicitly: makedepends and checkdepends, including the
# architecture-suffixed variants for the current CARCH.
install_deferred_build_dependencies() {
  local pkg="$1"
  local -a build_deps=()

  mapfile -t build_deps < <(
    env -u OMARCHY_SRC CARCH="$ARCH" bash -c '
      source ./PKGBUILD >/dev/null 2>&1 || exit 1
      arch_makedepends="makedepends_${CARCH}[@]"
      arch_checkdepends="checkdepends_${CARCH}[@]"
      printf "%s\n" \
        "${makedepends[@]}" "${!arch_makedepends}" \
        "${checkdepends[@]}" "${!arch_checkdepends}"
    ' | awk 'NF && !seen[$0]++'
  )

  if (( ${#build_deps[@]} )); then
    echo "    Installing build-only dependencies for $pkg..."
    sudo pacman -S --needed --noconfirm -- "${build_deps[@]}"
  fi
}

# Build a package
build_package() {
  local pkg="$1"
  local pkgdir
  pkgdir=$(find_package_dir "$pkg") || return 1

  echo ""
  echo "  -> Processing: $pkg"

  # Install this consumer's freshly built prerequisites in its own container.
  # Qualifying the repository also upgrades an older dependency baked into
  # the base image, even if that version would satisfy makepkg's check.
  if [[ "$DEFER_RUNTIME_DEPS" != true ]]; then
    local consumer dependency dep_dir dep_name dep_pkgname dep_pkgnames_out
    local -a dep_dirs=() built_deps=() dep_pkgnames=() matched_pkgnames=()
    while read -r consumer dependency; do
      [[ "$consumer" == "$pkg" ]] && dep_dirs+=("$dependency")
    done < "$BUILD_PLAN_DIR/dependencies"
    if (( ${#dep_dirs[@]} )); then
      local wanted_deps_out
      local -A wanted_deps=() seen_built_deps=()
      wanted_deps_out=$(get_package_deps "$pkg") || return 1
      while IFS= read -r dep_name; do
        [[ -n "$dep_name" ]] && wanted_deps["$dep_name"]=1
      done <<< "$wanted_deps_out"
      for dependency in "${dep_dirs[@]}"; do
        dep_dir=$(find_package_dir "$dependency") || return 1
        dep_pkgnames_out=$(read_pkgbuild_pkgnames "$dep_dir") || return 1
        mapfile -t dep_pkgnames <<< "$dep_pkgnames_out"
        matched_pkgnames=()
        for dep_pkgname in "${dep_pkgnames[@]}"; do
          [[ -n "${wanted_deps[$dep_pkgname]:-}" ]] && matched_pkgnames+=("$dep_pkgname")
        done
        if (( ! ${#matched_pkgnames[@]} )); then
          echo "    No matching package name from $dependency for $pkg" >&2
          return 1
        fi
        for dep_pkgname in "${matched_pkgnames[@]}"; do
          [[ -n "${seen_built_deps[$dep_pkgname]:-}" ]] && continue
          seen_built_deps["$dep_pkgname"]=1
          built_deps+=("omarchy-build/$dep_pkgname")
        done
      done
    fi
    if (( ${#built_deps[@]} )); then
      if [[ $BUILDER_ARCH != "$ARCH" ]]; then
        echo "    $pkg needs ${built_deps[*]#omarchy-build/} from this run, built for $ARCH, which cannot run on this $BUILDER_ARCH builder"
        return 1
      fi
      echo "    Installing freshly built dependencies for $pkg..."
      sudo /usr/local/bin/pacman-for-makepkg -S --needed --noconfirm -- "${built_deps[@]}" || return 1
    fi
  fi

  # Copy to build directory
  cd "$SRC_DIR" || return 1
  rm -rf "$pkg" || return 1
  cp -r "$pkgdir" "$pkg" || return 1
  cd "$SRC_DIR/$pkg" || return 1

  refresh_vcs_pkgver_preserving_local_pkgrel "$pkg" || {
    return 1
  }

  # Get PKGBUILD version (including epoch if present)
  local pkgbuild_version
  if ! pkgbuild_version=$(read_pkgbuild_version "$PWD"); then
    echo "    Failed to read PKGBUILD version"
    return 1
  fi

  # Show version info (version check already done in first pass)
  local local_version=$(get_local_version "$pkg")
  if [[ -n "$local_version" ]]; then
    echo "    Update available: $local_version -> $pkgbuild_version"
  else
    echo "    New package (version: $pkgbuild_version)"
  fi

  # The keys a recipe trusts ship with it (tests/pgp-keys-vendored.sh), so no
  # build waits on a keyserver.
  if [[ -d "keys/pgp" ]]; then
    echo "    Importing package-specific PGP keys..."
    for keyfile in keys/pgp/*.asc; do
      if [[ -f "$keyfile" ]]; then
        gpg --import "$keyfile" 2>/dev/null && echo "      Imported $(basename "$keyfile")" || echo "      Failed to import $(basename "$keyfile")"
      fi
    done
  fi

  # Build package without signing (signing is done separately)
  # PACMAN override uses a wrapper that adds --ask 4 to auto-resolve conflicts
  # (e.g. rustup replacing rust) since --noconfirm defaults to 'N' on those prompts
  local -a makepkg_flags=(-scf --noconfirm)
  if [[ $DEFER_RUNTIME_DEPS == "true" ]]; then
    # The pair's runtime dependencies (each other, and packages other jobs
    # of the same pipeline build) are not resolvable here; the assembled set
    # is installed in one verified transaction downstream. Only the
    # build-time dependencies are installed, then makepkg skips the check.
    install_deferred_build_dependencies "$pkg" || {
      return 1
    }
    makepkg_flags=(-cf --noconfirm --nodeps)
  fi

  if PACMAN=/usr/local/bin/pacman-for-makepkg makepkg "${makepkg_flags[@]}"; then
    # Ensure output directory exists
    mkdir -p "$BUILD_OUTPUT_DIR"

    # Copy only the artifacts makepkg declares as outputs. A PKGBUILD may use
    # another pacman package as a source (schist-bin does); a *.pkg.tar.* glob
    # would mistake that source archive for one of our freshly built packages.
    local -a package_files=()
    mapfile -t package_files < <(makepkg --packagelist)

    if [[ ${#package_files[@]} -eq 0 ]]; then
      echo "    Makepkg produced no package files for $pkg"
      return 1
    fi

    local -a new_pkgs=()
    local pkg_path pkg_file
    for pkg_path in "${package_files[@]}"; do
      pkg_file=${pkg_path##*/}
      if [[ ! -f "$pkg_file" ]]; then
        # makepkg predicts an automatic -debug output whenever debug is
        # enabled, but data-only packages may contain no symbols and therefore
        # legitimately produce no debug archive.
        if [[ "$pkg_file" == *-debug-*.pkg.tar.* ]]; then
          continue
        fi

        echo "    Expected package file was not produced: $pkg_file"
        return 1
      fi

      # pacman installs the owners a package records, so a package with a
      # file a local user would own never leaves the build.
      check_package_owners "$pkg_file" || return 1

      cp "$pkg_file" "$BUILD_OUTPUT_DIR/" || return 1
      new_pkgs+=("$pkg_file")
    done

    cd "$BUILD_OUTPUT_DIR" || return 1

    # Add every output from this build, including split packages.
    if [[ ${#new_pkgs[@]} -gt 0 ]]; then
      repo-add omarchy-build.db.tar.zst "${new_pkgs[@]}" >/dev/null 2>&1 || return 1
      ln -sf omarchy-build.db.tar.zst omarchy-build.db || return 1
    fi

    # A release may publish successful builds even when a peer fails. Record
    # outputs only after this package's entire split build has completed.
    mkdir -p "$BUILD_PLAN_DIR/artifacts" || return 1
    printf '%s\n' "${new_pkgs[@]}" > "$BUILD_PLAN_DIR/artifacts/$pkg" || return 1

    echo "    Successfully built $pkg"
    return 0
  else
    echo "    Makepkg failed for $pkg"
    echo "    DEBUG: Files in build directory:"
    ls -lah *.pkg.tar.* 2>&1 | head -20 || echo "    No package files found"
    return 1
  fi
}

# Get package dependency names from PKGBUILD (with version constraints stripped)
get_package_deps() {
  local pkg="$1"
  local pkgdir
  pkgdir=$(find_package_dir "$pkg") || return 0
  local pkgbuild="$pkgdir/PKGBUILD"

  if [[ ! -f "$pkgbuild" ]]; then
    return
  fi

  # Include test dependencies and target-specific arrays: each container must
  # receive its prerequisites through the repository, not a previous build.
  local deps_out
  deps_out=$(
    cd "$pkgdir" && env -u OMARCHY_SRC CARCH="$ARCH" bash -c '
      source ./PKGBUILD >/dev/null 2>&1 || exit 1
      for kind in depends makedepends checkdepends; do
        generic="${kind}[@]"
        specific="${kind}_${CARCH}[@]"
        printf "%s\n" "${!generic}" "${!specific}"
      done
    '
  ) || return 1
  printf '%s\n' "$deps_out" | sed 's/[<>=].*$//' | awk 'NF && !seen[$0]++'
}

# For VCS packages (those with a pkgver() function), the static pkgver= in the
# PKGBUILD is just a placeholder; the real version is computed at build time
# from the git checkout. Without this check, version comparison always reports a
# mismatch and we rebuild on every run, producing a package with the same
# name+version as one already in production. Detect this by comparing the
# upstream commit hash to the hash suffix already in the production version
# (both `...gabcdef0` and `...abcdef0` styles are common). Returns 0 when
# upstream is unchanged (build can be skipped).
check_vcs_unchanged() {
  local pkgbuild_version="$1"
  local prod_version="$2"
  local upstream_hash="$3"
  [[ -n "$pkgbuild_version" && -n "$prod_version" && -n "$upstream_hash" ]] || return 1

  local pkgbuild_pkgrel="${pkgbuild_version##*-}"
  local pkgbuild_no_pkgrel="${pkgbuild_version%-*}"
  local pkgbuild_epoch=""
  [[ "$pkgbuild_no_pkgrel" == *:* ]] && pkgbuild_epoch="${pkgbuild_no_pkgrel%%:*}"

  local prod_pkgrel="${prod_version##*-}"
  local prod_no_pkgrel="${prod_version%-*}"
  local prod_epoch=""
  [[ "$prod_no_pkgrel" == *:* ]] && prod_epoch="${prod_no_pkgrel%%:*}"

  [[ "$pkgbuild_epoch" == "$prod_epoch" ]] || return 1
  [[ "$pkgbuild_pkgrel" == "$prod_pkgrel" ]] || return 1
  version_matches_hash "$prod_version" "$upstream_hash"
}

# Check which packages need building (version check only)
check_needs_build() {
  local pkg="$1"
  local pkgdir=$(find_package_dir "$pkg")
  local pkgbuild="$pkgdir/PKGBUILD"

  [[ ! -f "$pkgbuild" ]] && return 1

  # Get PKGBUILD version (including epoch if present)
  local pkgbuild_version
  if ! pkgbuild_version=$(read_pkgbuild_version "$pkgdir"); then
    echo "==> ERROR: Failed to read PKGBUILD version for $pkg" >&2
    return 2
  fi

  local pkgnames_out pkgname_item
  local -a pkgnames=()
  if ! pkgnames_out=$(read_pkgbuild_pkgnames "$pkgdir"); then
    echo "==> ERROR: Failed to read PKGBUILD pkgname for $pkg" >&2
    return 2
  fi
  mapfile -t pkgnames <<< "$pkgnames_out"

  load_local_versions
  local -a target_versions=()
  local is_vcs=0

  if grep -qE '^pkgver[[:space:]]*\(\)' "$pkgbuild"; then
    is_vcs=1
    local -A seen_cand_vers=()
    local -a cand_vers=()
    local cand_ver vcs_has_hash=0 upstream_hash=""
    for pkgname_item in "${pkgnames[@]}"; do
      cand_ver="${LOCAL_VERSION_BY_NAME[$pkgname_item]:-}"
      if [[ -n "$cand_ver" && -z "${seen_cand_vers[$cand_ver]:-}" ]]; then
        seen_cand_vers["$cand_ver"]=1
        cand_vers+=("$cand_ver")
      fi
    done
    local -A seen_targets=()
    upstream_hash=$(package_git_upstream_hash --full "$pkgdir")
    for cand_ver in "${cand_vers[@]}"; do
      if [[ -n "$(extract_vcs_hash "$cand_ver")" ]]; then
        vcs_has_hash=1
        if check_vcs_unchanged "$pkgbuild_version" "$cand_ver" "$upstream_hash"; then
          target_versions+=("$cand_ver")
          seen_targets["$cand_ver"]=1
        fi
      fi
    done
    if [[ -z "${seen_targets[$pkgbuild_version]:-}" ]]; then
      if (( ! vcs_has_hash )) && [[ -n "${seen_cand_vers[$pkgbuild_version]:-}" ]]; then
        target_versions+=("$pkgbuild_version")
      elif version_matches_hash "$pkgbuild_version" "$upstream_hash"; then
        target_versions+=("$pkgbuild_version")
      fi
    fi
    (( ${#target_versions[@]} > 0 )) || return 0
  else
    target_versions+=("$pkgbuild_version")
  fi

  # Evaluate publication per output pkgname across target_versions and decide
  # from the highest published/partial version(s) via vercmp: completely
  # unpublished higher static versions never hide a partial DB release, older
  # complete releases never hide a newer partial one, and tied equal-precedence
  # versions fail closed if any is partial (independent of pkgname order).
  local target_version cmp_rc best_ver="" best_has_complete=0 best_complete_msg="" best_partial_err=""
  for target_version in "${target_versions[@]}"; do
    local -a db_missing=() archive_missing=()
    local db_present=0 archive_present=0 state="" msg=""
    for pkgname_item in "${pkgnames[@]}"; do
      if [[ "${LOCAL_VERSION_BY_NAME[$pkgname_item]:-}" == "$target_version" ]]; then
        ((db_present++))
      else
        db_missing+=("$pkgname_item")
      fi
    done
    if (( ${#db_missing[@]} == 0 )); then
      state="complete"
    else
      for pkgname_item in "${db_missing[@]}"; do
        if package_version_is_published "$FINAL_OUTPUT_DIR" "$pkgname_item" "$target_version" "$ARCH"; then
          ((archive_present++))
        else
          archive_missing+=("$pkgname_item")
        fi
      done
      if (( ${#archive_missing[@]} > 0 )) && [[ -n "$PUBLISHED_REPO_SERVER" ]]; then
        local -A remote_found=()
        local remote_name
        while IFS= read -r remote_name; do
          [[ -n "$remote_name" ]] && remote_found["$remote_name"]=1
        done < <(remote_published_pkgnames "$target_version" "${archive_missing[@]}")
        local -a still_missing=()
        for pkgname_item in "${archive_missing[@]}"; do
          if [[ -n "${remote_found[$pkgname_item]:-}" ]]; then
            ((archive_present++))
          else
            still_missing+=("$pkgname_item")
          fi
        done
        archive_missing=("${still_missing[@]}")
      fi
      if (( ${#archive_missing[@]} == 0 )); then
        state="complete"
        msg="  + $pkg $target_version - archive already published; skipping rebuild"
      elif (( db_present > 0 || archive_present > 0 )); then
        state="partial"
        if (( is_vcs )); then
          msg="==> ERROR: $pkg $target_version is partially published (missing: ${archive_missing[*]}); update pkgver with a pkgrel bump or use a dotted pkgrel to rebuild"
        else
          msg="==> ERROR: $pkg $target_version is partially published (missing: ${archive_missing[*]}); bump pkgrel to rebuild"
        fi
      else
        continue
      fi
    fi

    if [[ -z "$best_ver" ]]; then
      cmp_rc=1
    elif ! cmp_rc=$(vercmp "$target_version" "$best_ver"); then
      echo "==> ERROR: vercmp is required to compare multiple candidate versions for $pkg" >&2
      return 2
    fi
    if (( cmp_rc > 0 )); then
      best_ver="$target_version"
      best_has_complete=0
      best_complete_msg=""
      best_partial_err=""
    fi
    if (( cmp_rc >= 0 )); then
      if [[ "$state" == "partial" ]]; then
        [[ -z "$best_partial_err" ]] && best_partial_err="$msg"
      else
        best_has_complete=1
        [[ -z "$best_complete_msg" ]] && best_complete_msg="$msg"
      fi
    fi
  done

  if [[ -n "$best_partial_err" ]]; then
    echo "$best_partial_err" >&2
    return 2
  fi
  if (( best_has_complete )); then
    [[ -n "$best_complete_msg" ]] && echo "$best_complete_msg"
    return 1
  fi

  return 0  # Needs building
}

# Collect packages that should be built for the selected mirror
collect_packages() {
  # A package that cross-compiles builds only in its own builder image.
  local pkgdir pkg arch_rc
  while IFS= read -r pkgdir; do
    package_builds_for_mirror "$pkgdir" "$MIRROR" || continue
    package_build_skipped "$pkgdir" && continue
    pkg=$(basename "$pkgdir")
    arch_rc=0
    should_build_for_arch "$pkg" || arch_rc=$?
    if (( arch_rc == 0 )); then
      echo "$pkg"
    elif (( arch_rc == 1 )); then
      if package_supports_arch "$pkgdir" "$ARCH"; then
        echo "  - $pkg - builds for $ARCH in the $(package_build_host "$pkg" "$ARCH") builder image" >&2
      fi
    else
      echo "==> ERROR: Failed to read PKGBUILD for $pkg" >&2
      return 2
    fi
  done < <(package_dirs)
}

# Main execution
if [[ "$DRY_RUN" != true ]]; then
  cd "$SRC_DIR" || exit 1
  build_package "$BUILD_PACKAGE"
  exit $?
fi

echo "==> Checking which packages need building..."

# First pass: determine which packages need building
PACKAGES_TO_BUILD=()
ORDERED_PACKAGES=()
PLANNED_DEPENDENCIES=()

# If PACKAGES is specified, only check those packages
if [[ -n "$PACKAGES" ]]; then
  echo "==> Checking specified packages: $PACKAGES"
  for pkg_name in $PACKAGES; do
    pkgdir=$(find_package_dir "$pkg_name")
    if [[ -z "$pkgdir" || ! -f "$pkgdir/PKGBUILD" ]]; then
      echo "==> ERROR: Package '$pkg_name' not found in $PKGBUILDS_DIR"
      exit 1
    fi

    if ! package_builds_for_mirror "$pkgdir" "$MIRROR"; then
      if [[ "$MIRROR" == "stable" ]]; then
        echo "  - $pkg_name - not in release_ring=fast; build edge and promote with repo migrate"
      else
        echo "  - $pkg_name - not configured for direct $MIRROR builds"
      fi
      SKIPPED_PACKAGES="$SKIPPED_PACKAGES $pkg_name"
      continue
    fi

    # Check if package should be built for this architecture
    arch_rc=0
    should_build_for_arch "$pkg_name" || arch_rc=$?
    if (( arch_rc == 1 )); then
      echo "  - $pkg_name - not built for $ARCH"
      SKIPPED_PACKAGES="$SKIPPED_PACKAGES $pkg_name"
      continue
    elif (( arch_rc != 0 )); then
      echo "==> ERROR: Failed to read PKGBUILD for $pkg_name" >&2
      exit 1
    fi

    needs_rc=0
    check_needs_build "$pkg_name" || needs_rc=$?
    if (( needs_rc == 0 )); then
      PACKAGES_TO_BUILD+=("$pkg_name")
    elif (( needs_rc == 1 )); then
      echo "  + $pkg_name - already up to date"
      SKIPPED_PACKAGES="$SKIPPED_PACKAGES $pkg_name"
    else
      exit 1
    fi
  done
else
  # Build all packages that need updates from the relevant directories
  collected_pkgs=$(collect_packages) || exit 1
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    needs_rc=0
    check_needs_build "$pkg" || needs_rc=$?
    if (( needs_rc == 0 )); then
      PACKAGES_TO_BUILD+=("$pkg")
    elif (( needs_rc == 1 )); then
      echo "  + $pkg - already up to date"
      SKIPPED_PACKAGES="$SKIPPED_PACKAGES $pkg"
    else
      exit 1
    fi
  done <<< "$collected_pkgs"
fi

if [[ ${#PACKAGES_TO_BUILD[@]} -eq 0 ]]; then
  echo "==> All packages are up to date!"
else
  echo "==> ${#PACKAGES_TO_BUILD[@]} package(s) need building: ${PACKAGES_TO_BUILD[*]}"
  echo "==> Determining build order based on dependencies..."

  # Second pass: order only the packages that need building
  # Strategy: build packages with no unmet dependencies first
  declare -A unmet_deps_count  # How many dependencies does this package still need?
  declare -A blocks_packages    # Which packages are waiting for this one?

  # Count unmet dependencies for each package
  for pkg in "${PACKAGES_TO_BUILD[@]}"; do
    unmet_deps_count[$pkg]=0
  done

  # Map every pkgname produced by this run to its recipe directory so split
  # packages and pkgbase!=pkgname recipes are ordered and recorded properly.
  declare -A pkgname_to_dir=()
  for build_pkg in "${PACKAGES_TO_BUILD[@]}"; do
    pkgdir=$(find_package_dir "$build_pkg") || exit 1
    pkgnames_out=$(read_pkgbuild_pkgnames "$pkgdir") || {
      echo "==> ERROR: Failed to read PKGBUILD pkgname for $build_pkg" >&2
      exit 1
    }
    while IFS= read -r produced_name; do
      [[ -n "$produced_name" ]] && pkgname_to_dir["$produced_name"]="$build_pkg"
    done <<< "$pkgnames_out"
  done

  # Build the dependency relationships
  for pkg in "${PACKAGES_TO_BUILD[@]}"; do
    declare -A seen_dep_dirs=()
    pkg_deps_out=$(get_package_deps "$pkg") || {
      echo "==> ERROR: Failed to read PKGBUILD dependencies for $pkg" >&2
      exit 1
    }
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      dep_dir="${pkgname_to_dir[$dep]:-}"
      [[ -n "$dep_dir" && "$dep_dir" != "$pkg" && -z "${seen_dep_dirs[$dep_dir]:-}" ]] || continue
      seen_dep_dirs["$dep_dir"]=1
      # pkg needs dep_dir, so increment pkg's unmet count
      ((unmet_deps_count[$pkg]++))
      # Track that dep_dir blocks pkg from building
      blocks_packages[$dep_dir]="${blocks_packages[$dep_dir]} $pkg"
      PLANNED_DEPENDENCIES+=("$pkg $dep_dir")
    done <<< "$pkg_deps_out"
    unset seen_dep_dirs
  done

  # Start with packages that have all dependencies met (count = 0)
  ready_to_build=()
  for pkg in "${PACKAGES_TO_BUILD[@]}"; do
    if [[ ${unmet_deps_count[$pkg]} -eq 0 ]]; then
      ready_to_build+=("$pkg")
    fi
  done

  # Build packages as dependencies become available
  while [[ ${#ready_to_build[@]} -gt 0 ]]; do
    # Take the first ready package
    current="${ready_to_build[0]}"
    ready_to_build=("${ready_to_build[@]:1}")
    ORDERED_PACKAGES+=("$current")

    # This package is now built, so packages waiting for it can proceed
    for blocked_pkg in ${blocks_packages[$current]}; do
      ((unmet_deps_count[$blocked_pkg]--))
      if [[ ${unmet_deps_count[$blocked_pkg]} -eq 0 ]]; then
        ready_to_build+=("$blocked_pkg")
      fi
    done
  done

  # Check for circular dependencies
  if [[ ${#ORDERED_PACKAGES[@]} -ne ${#PACKAGES_TO_BUILD[@]} ]]; then
    echo "ERROR: Circular dependency detected!"
    exit 1
  fi

  echo "==> Build order: ${ORDERED_PACKAGES[*]}"
fi

# The host consumes plain data, never shell code or parsed human log output.
if [[ -n "$BUILD_PLAN_DIR" ]]; then
  mkdir -p "$BUILD_PLAN_DIR" || exit 1
  printf '%s\n' "${ORDERED_PACKAGES[@]}" | sed '/^$/d' > "$BUILD_PLAN_DIR/packages" || exit 1
  printf '%s\n' "${PLANNED_DEPENDENCIES[@]}" | sed '/^$/d' > "$BUILD_PLAN_DIR/dependencies" || exit 1
  printf '%s\n' $SKIPPED_PACKAGES | sed '/^$/d' > "$BUILD_PLAN_DIR/skipped" || exit 1
fi

echo ""
echo "==> Plan complete. Packages that would build: ${ORDERED_PACKAGES[*]}"
