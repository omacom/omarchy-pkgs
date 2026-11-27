#!/bin/bash
# Integration regression: uses real containers, makepkg, repo-add and pacman.
# Requires the normal builder image (or TEST_BUILDER_IMAGE) for this platform.
set -euo pipefail

BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
source "$BUILD_ROOT/helpers/message-helpers.sh"
source "$BUILD_ROOT/helpers/docker-helpers.sh"
check_engine
TEST_ARCH=$(docker_native_arch)
TEST_BUILDER_IMAGE=${TEST_BUILDER_IMAGE:-omarchy-pkg-builder:latest-$TEST_ARCH-edge}
TEST_ENGINE=$(command -v "$CONTAINER_ENGINE")
TEST_RUN_ID="build-isolation-$$"
TEST_ROOT=$(mktemp -d)
PIDS=()
cleanup() {
  if (( ${#PIDS[@]} )); then
    local pid cid
    for pid in "${PIDS[@]}"; do
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
    done
    while IFS= read -r cid; do
      [[ -n "$cid" ]] && "$TEST_ENGINE" rm -f "$cid" >/dev/null 2>&1 || true
    done < <("$TEST_ENGINE" ps -q --filter "label=omarchy.test.run=$TEST_RUN_ID" 2>/dev/null || true)
    for pid in "${PIDS[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
  fi
  rm -rf "$TEST_ROOT"
}
trap 'exit 130' INT
trap 'exit 143' TERM
trap cleanup EXIT

# Prepare a host-owned fast libmakepkg overlay once against the test image so
# fixture builds avoid per-attribute makepkg fork storms. Falls back cleanly to
# stock makepkg if the helper declines to patch the image's libmakepkg.
TEST_FAST_MAKEPKG_LIB=""
if [[ -f "$BUILD_ROOT/helpers/fast-makepkg.sh" ]]; then
  mkdir -p "$TEST_ROOT/fastlib"
  if "$TEST_ENGINE" run "${CONTAINER_RUN_ARGS[@]}" --rm \
      -v "$BUILD_ROOT/helpers:/helpers:ro" \
      "$TEST_BUILDER_IMAGE" \
      bash -lc 'out=$(bash /helpers/fast-makepkg.sh /tmp/fastlib) && [[ "$out" == /tmp/fastlib ]] && tar -C "$out" -cf - .' \
      | tar -C "$TEST_ROOT/fastlib" -xf -; then
    TEST_FAST_MAKEPKG_LIB="$TEST_ROOT/fastlib"
  fi
fi

# The runner expects the normal image tag. Use an engine wrapper to select
# the supplied test image without overwriting an operator's builder image.
mkdir "$TEST_ROOT/engine"
cat > "$TEST_ROOT/engine/$CONTAINER_ENGINE" <<'ENGINE'
#!/bin/bash
args=("$@")
for index in "${!args[@]}"; do
  if [[ "${args[$index]}" == omarchy-pkg-builder:latest-* ]]; then
    args[$index]="$TEST_BUILDER_IMAGE"
  fi
done
if [[ "${args[0]:-}" == "run" ]]; then
  extra=(--label "omarchy.test.run=$TEST_RUN_ID")
  if [[ -n "${TEST_FAST_MAKEPKG_LIB:-}" ]]; then
    extra+=(-v "$TEST_FAST_MAKEPKG_LIB:/fast-libmakepkg:ro" -e MAKEPKG_LIBRARY=/fast-libmakepkg)
  fi
  exec "$TEST_ENGINE" run "${extra[@]}" "${args[@]:1}"
fi
exec "$TEST_ENGINE" "${args[@]}"
ENGINE
chmod +x "$TEST_ROOT/engine/$CONTAINER_ENGINE"
export TEST_ENGINE TEST_BUILDER_IMAGE TEST_FAST_MAKEPKG_LIB TEST_RUN_ID
export PATH="$TEST_ROOT/engine:$PATH"
export OMARCHY_SKIP_BUILDER_IMAGE=1
# Offline fixtures never publish to or resolve from the live channel.
export OMARCHY_PUBLISHED_REPO_URL=""
unset OMARCHY_RC_PINS OMARCHY_DEFER_RUNTIME_DEPS OMARCHY_KEEP_BUILD_WORKSPACE

init_workspace() {
  local ws=$1
  mkdir -p "$ws/bin" "$ws/pkgbuilds" "$ws/build-output/edge/$TEST_ARCH"
  cp "$BUILD_ROOT/bin/build" "$ws/bin/"
  cp -r "$BUILD_ROOT/build" "$BUILD_ROOT/helpers" "$ws/"
}

fixture() {
  local ws=$1 name=$2 metadata=$3
  mkdir -p "$ws/pkgbuilds/$name/.omarchy"
  printf '{"source":"local"}\n' > "$ws/pkgbuilds/$name/.omarchy/package.json"
  cat > "$ws/pkgbuilds/$name/PKGBUILD" <<EOF
pkgname=$name
pkgver=1
pkgrel=1
arch=('x86_64' 'aarch64')
pkgdesc='Build isolation regression fixture'
license=('MIT')
options=('!debug')
$metadata
package() {
  [[ ! -e /tmp/omarchy-build-contamination ]] || return 1
  touch /tmp/omarchy-build-contamination
  install -Dm644 /dev/null "\$pkgdir/usr/share/build-isolation/\$pkgname"
}
EOF
}

run_build() {
  local ws=$1
  shift
  "$ws/bin/build" --arch "$TEST_ARCH" --package "$@"
}

# Worker 1: keyring, scratch tmpfs check, and empty-plan check.
run_worker_misc() {
  local ws="$TEST_ROOT/w-misc"
  init_workspace "$ws"

  # Exercise keyring population even if the image's keyring package is current.
  fixture "$ws" keyring ''
  cat >> "$ws/pkgbuilds/keyring/PKGBUILD" <<'EOF'
check() { sudo pacman-key --populate archlinux; }
EOF
  run_build "$ws" keyring > "$ws/keyring.log" 2>&1 || {
    cat "$ws/keyring.log"
    exit 1
  }
  printf 'PASS: keyring population works without a private key in the image\n'

  # Compilers write their temporaries to /tmp, so it lives in memory rather
  # than on the builder's disk, and configure scripts must still be able to run
  # the test programs they build there.
  fixture "$ws" scratch ''
  cat >> "$ws/pkgbuilds/scratch/PKGBUILD" <<'EOF'
check() {
  # The filesystem type and superblock options of a tmpfs mounted at $1 in
  # its own right. A bind mount of a host directory that happens to sit on
  # tmpfs has that directory, not /, as its root, so it prints nothing.
  own_mount() {
    awk -v target="$1" '$4 == "/" && $5 == target { sub(/.* - /, ""); print }' /proc/self/mountinfo
  }
  # Configure scripts and build systems run the programs they compile both
  # in /tmp and in the source tree.
  exec_probe() {
    printf '#!/bin/sh\nexit 0\n' > "$1/omarchy-exec-probe"
    chmod +x "$1/omarchy-exec-probe"
    "$1/omarchy-exec-probe"
  }
  [[ $(own_mount /tmp) == "tmpfs "*"size=16777216k"* ]]
  exec_probe /tmp
  [[ $srcdir == /src/* ]]
  exec_probe "$srcdir"
  # The source tree moves to memory only where a kernel tree fits.
  if (( $(awk '/^MemTotal:/ { print $2 }' /proc/meminfo) >= 56 * 1024 * 1024 )); then
    [[ $(own_mount /src) == "tmpfs "*"size=41943040k"* ]]
  else
    [[ $(own_mount /src) != tmpfs\ * ]]
  fi
}
EOF
  run_build "$ws" scratch > "$ws/scratch.log" 2>&1 || {
    cat "$ws/scratch.log"
    exit 1
  }
  printf 'PASS: /tmp, and /src on large hosts, are executable tmpfs mounts\n'

  fixture "$ws" excluded ''
  local other_arch=aarch64
  [[ $TEST_ARCH == aarch64 ]] && other_arch=x86_64
  sed -i "s/^arch=.*/arch=('$other_arch')/" "$ws/pkgbuilds/excluded/PKGBUILD"
  run_build "$ws" excluded > "$ws/empty.log" 2>&1 || { cat "$ws/empty.log"; exit 1; }
  grep -q 'Total packages: 0' "$ws/empty.log"
  if grep -q 'in a fresh container' "$ws/empty.log"; then
    echo 'FAIL: an excluded package started a build container' >&2
    exit 1
  fi
  printf 'PASS: empty plans finish without starting a package build\n'
}

# Worker 2: release/dev pairs and Flea in one isolated build run.
run_worker_pairs() {
  local ws="$TEST_ROOT/w-pairs"
  init_workspace "$ws"

  fixture "$ws" omarchy-settings ''
  fixture "$ws" omarchy "depends=('omarchy-settings=1')"
  fixture "$ws" omarchy-settings-dev "provides=('omarchy-settings'); conflicts=('omarchy-settings')"
  fixture "$ws" omarchy-dev "depends=('omarchy-settings-dev'); provides=('omarchy'); conflicts=('omarchy')"
  fixture "$ws" flea "depends=('omarchy')"

  # Both pairs and their consumer in one run. Every package also leaves a
  # /tmp marker: even non-package filesystem changes must stay isolated.
  run_build "$ws" omarchy-settings omarchy-settings-dev omarchy omarchy-dev flea > "$ws/pairs.log" 2>&1 || {
    cat "$ws/pairs.log"
    exit 1
  }
  local package
  for package in flea omarchy omarchy-dev omarchy-settings omarchy-settings-dev; do
    compgen -G "$ws/build-output/edge/$TEST_ARCH/$package-1-1-*.pkg.tar.zst" >/dev/null
  done
  printf 'PASS: release/dev pairs and Flea build together in isolated roots\n'
}

# Worker 3: failure blocking -> kept workspace -> rebuilt artifact cache invalidation.
run_worker_chain() {
  local ws="$TEST_ROOT/w-chain"
  init_workspace "$ws"

  # Test-only and architecture-specific dependencies must precede consumers.
  # Failure must block both direct and transitive consumers, while an
  # unrelated package still builds in a clean container.
  fixture "$ws" broken ''
  cat >> "$ws/pkgbuilds/broken/PKGBUILD" <<'EOF'
prepare() { touch /tmp/omarchy-build-contamination; return 1; }
EOF
  fixture "$ws" consumer "checkdepends_${TEST_ARCH}=('broken')"
  fixture "$ws" transitive "makedepends=('consumer')"
  fixture "$ws" independent ''
  local failure_status=0
  OMARCHY_BUILD_RESULT_DIR="$ws/results" run_build "$ws" transitive consumer broken independent > "$ws/failure.log" 2>&1 || failure_status=$?
  if [[ "$failure_status" != 2 ]]; then
    cat "$ws/failure.log"
    echo "FAIL: expected completed package failure (2), got $failure_status" >&2
    exit 1
  fi
  [[ -f "$ws/results/complete" ]]
  [[ $(cat "$ws/results/failed") == broken ]]
  [[ $(cat "$ws/results/blocked") == $'transitive\nconsumer' || $(cat "$ws/results/blocked") == $'consumer\ntransitive' ]]
  [[ $(cat "$ws/results/artifacts") == "independent-1-1-$TEST_ARCH.pkg.tar.zst" ]]
  grep -q 'consumer blocked by unsuccessful dependency: broken' "$ws/failure.log"
  grep -q 'transitive blocked by unsuccessful dependency: consumer' "$ws/failure.log"
  compgen -G "$ws/build-output/edge/$TEST_ARCH/independent-1-1-*.pkg.tar.zst" >/dev/null
  if compgen -G "$ws/build-output/edge/$TEST_ARCH/consumer-*.pkg.tar.zst" >/dev/null; then
    echo 'FAIL: consumer of a failed prerequisite was built' >&2
    exit 1
  fi
  printf 'PASS: failed prerequisite blocks consumers; independent build remains clean\n'

  # A later job can resolve dependencies from artifacts kept by the caller.
  # Make consumer depend on the already staged fixture without selecting it.
  sed -i "s/^checkdepends_.*/depends=('independent')/" "$ws/pkgbuilds/consumer/PKGBUILD"
  OMARCHY_KEEP_BUILD_WORKSPACE=1 run_build "$ws" consumer > "$ws/seeded.log" 2>&1 || {
    cat "$ws/seeded.log"
    exit 1
  }
  compgen -G "$ws/build-output/edge/$TEST_ARCH/consumer-1-1-*.pkg.tar.zst" >/dev/null
  printf 'PASS: kept workspace supplies dependencies to a later isolated build\n'

  # A rebuild may keep its filename while changing its bytes. Pacman's shared
  # cache must not hide the replacement artifact from the next consumer.
  cat >> "$ws/pkgbuilds/independent/PKGBUILD" <<'EOF'
package() {
  install -Dm644 /dev/null "$pkgdir/usr/share/build-isolation/independent"
  echo replacement > "$pkgdir/usr/share/build-isolation/independent"
}
EOF
  cat >> "$ws/pkgbuilds/consumer/PKGBUILD" <<'EOF'
check() { [[ $(cat /usr/share/build-isolation/independent) == replacement ]]; }
EOF
  OMARCHY_KEEP_BUILD_WORKSPACE=1 run_build "$ws" independent consumer > "$ws/rebuilt.log" 2>&1 || {
    cat "$ws/rebuilt.log"
    exit 1
  }
  printf 'PASS: rebuilt artifacts supersede cached packages with the same filename\n'
}

# Worker 4: deferred pair mode and non-root file ownership rejection.
run_worker_deferred_and_owner() {
  local ws="$TEST_ROOT/w-deferred"
  init_workspace "$ws"

  # CI's deferred pair mode still accepts the complete request although each
  # half now builds in its own container. An unavailable runtime dependency
  # proves it was deferred; build/test dependencies still use pacman normally.
  fixture "$ws" omarchy-settings-dev "provides=('omarchy-settings'); conflicts=('omarchy-settings')"
  fixture "$ws" omarchy-dev "depends=('omarchy-settings-dev' 'unavailable-runtime-fixture'); provides=('omarchy'); conflicts=('omarchy')"
  OMARCHY_DEFER_RUNTIME_DEPS=true run_build "$ws" omarchy-dev omarchy-settings-dev > "$ws/deferred.log" 2>&1 || {
    cat "$ws/deferred.log"
    exit 1
  }
  compgen -G "$ws/build-output/edge/$TEST_ARCH/omarchy-dev-1-1-*.pkg.tar.zst" >/dev/null
  printf 'PASS: deferred pair mode works across isolated containers\n'

  # pacman installs the owners a package records, so a file left owned by a
  # build machine's uid must stop the build before it reaches the output.
  fixture "$ws" runner-owned ''
  cat >> "$ws/pkgbuilds/runner-owned/PKGBUILD" <<'EOF'
package() {
  install -Dm755 /dev/null "$pkgdir/opt/runner-owned/app"
  chown -R 1001:1001 "$pkgdir/opt/runner-owned"
}
EOF
  local owner_status=0
  OMARCHY_BUILD_RESULT_DIR="$ws/owner-results" run_build "$ws" runner-owned > "$ws/owner.log" 2>&1 || owner_status=$?
  if (( owner_status != 2 )); then
    cat "$ws/owner.log"
    echo "FAIL: expected a refused package (2), got $owner_status" >&2
    exit 1
  fi
  [[ $(cat "$ws/owner-results/failed") == "runner-owned" ]]
  grep -q 'files that pacman would install with a non-root owner' "$ws/owner.log"
  if compgen -G "$ws/build-output/edge/$TEST_ARCH/runner-owned-*.pkg.tar.zst" >/dev/null; then
    echo 'FAIL: a package with a uid 1001 file reached the build output' >&2
    exit 1
  fi
  printf 'PASS: a package with a file owned by uid 1001 never reaches the output\n'
}

# Run the four independent scenario groups concurrently, buffering each
# worker's output so logs stay readable and checking every exit status.
LOGS=(
  "$TEST_ROOT/w-misc.out"
  "$TEST_ROOT/w-pairs.out"
  "$TEST_ROOT/w-chain.out"
  "$TEST_ROOT/w-deferred.out"
)
run_worker_misc > "${LOGS[0]}" 2>&1 &
PIDS+=($!)
run_worker_pairs > "${LOGS[1]}" 2>&1 &
PIDS+=($!)
run_worker_chain > "${LOGS[2]}" 2>&1 &
PIDS+=($!)
run_worker_deferred_and_owner > "${LOGS[3]}" 2>&1 &
PIDS+=($!)

status=0
for i in "${!PIDS[@]}"; do
  rc=0
  wait "${PIDS[i]}" || rc=$?
  cat "${LOGS[i]}"
  if (( rc != 0 )); then
    status=$rc
  fi
done
PIDS=()
exit "$status"
