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
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/pkgbuilds" "$TEST_ROOT/build-output/edge/$TEST_ARCH"
cp "$BUILD_ROOT/bin/build" "$TEST_ROOT/bin/"
cp -r "$BUILD_ROOT/build" "$BUILD_ROOT/helpers" "$TEST_ROOT/"
# No external verification keys are needed for source-free fixtures.
: > "$TEST_ROOT/build/gpg-keys.txt"

# The runner expects the normal image tag. Use an engine wrapper to select
# the supplied test image without overwriting an operator's builder image.
TEST_ENGINE=$(command -v "$CONTAINER_ENGINE")
mkdir "$TEST_ROOT/engine"
cat > "$TEST_ROOT/engine/$CONTAINER_ENGINE" <<'ENGINE'
#!/bin/bash
args=("$@")
for index in "${!args[@]}"; do
  if [[ "${args[$index]}" == omarchy-pkg-builder:latest-* ]]; then
    args[$index]="$TEST_BUILDER_IMAGE"
  fi
done
exec "$TEST_ENGINE" "${args[@]}"
ENGINE
chmod +x "$TEST_ROOT/engine/$CONTAINER_ENGINE"
export TEST_ENGINE TEST_BUILDER_IMAGE
export PATH="$TEST_ROOT/engine:$PATH"
export OMARCHY_SKIP_BUILDER_IMAGE=1
unset OMARCHY_REPO_ROOT OMARCHY_RC_PINS OMARCHY_DEFER_RUNTIME_DEPS OMARCHY_KEEP_BUILD_WORKSPACE

fixture() {
  local name=$1 metadata=$2
  mkdir -p "$TEST_ROOT/pkgbuilds/$name/.omarchy"
  printf '{"source":"local"}\n' > "$TEST_ROOT/pkgbuilds/$name/.omarchy/package.json"
  cat > "$TEST_ROOT/pkgbuilds/$name/PKGBUILD" <<EOF
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
  "$TEST_ROOT/bin/build" --arch "$TEST_ARCH" --package "$@"
}

# Exercise keyring population even if the image's keyring package is current.
fixture keyring ''
cat >> "$TEST_ROOT/pkgbuilds/keyring/PKGBUILD" <<'EOF'
check() { sudo pacman-key --populate archlinux; }
EOF
run_build keyring > "$TEST_ROOT/keyring.log" 2>&1 || {
  cat "$TEST_ROOT/keyring.log"
  exit 1
}
printf 'PASS: keyring population works without a private key in the image\n'

fixture omarchy-settings ''
fixture omarchy "depends=('omarchy-settings=1')"
fixture omarchy-settings-dev "provides=('omarchy-settings'); conflicts=('omarchy-settings')"
fixture omarchy-dev "depends=('omarchy-settings-dev'); provides=('omarchy'); conflicts=('omarchy')"
fixture flea "depends=('omarchy')"

# Both pairs and their consumer in one run. Every package also leaves a
# /tmp marker: even non-package filesystem changes must stay isolated.
run_build omarchy-settings omarchy-settings-dev omarchy omarchy-dev flea > "$TEST_ROOT/pairs.log" 2>&1 || {
  cat "$TEST_ROOT/pairs.log"
  exit 1
}
for package in flea omarchy omarchy-dev omarchy-settings omarchy-settings-dev; do
  compgen -G "$TEST_ROOT/build-output/edge/$TEST_ARCH/$package-1-1-*.pkg.tar.zst" >/dev/null
done
printf 'PASS: release/dev pairs and Flea build together in isolated roots\n'

# Test-only and architecture-specific dependencies must precede consumers.
# Failure must block both direct and transitive consumers, while an
# unrelated package still builds in a clean container.
fixture broken ''
cat >> "$TEST_ROOT/pkgbuilds/broken/PKGBUILD" <<'EOF'
prepare() { touch /tmp/omarchy-build-contamination; return 1; }
EOF
fixture consumer "checkdepends_${TEST_ARCH}=('broken')"
fixture transitive "makedepends=('consumer')"
fixture independent ''
if run_build transitive consumer broken independent > "$TEST_ROOT/failure.log" 2>&1; then
  cat "$TEST_ROOT/failure.log"
  echo 'FAIL: a failed prerequisite did not fail the run' >&2
  exit 1
fi
grep -q 'consumer blocked by unsuccessful dependency: broken' "$TEST_ROOT/failure.log"
grep -q 'transitive blocked by unsuccessful dependency: consumer' "$TEST_ROOT/failure.log"
compgen -G "$TEST_ROOT/build-output/edge/$TEST_ARCH/independent-1-1-*.pkg.tar.zst" >/dev/null
if compgen -G "$TEST_ROOT/build-output/edge/$TEST_ARCH/consumer-*.pkg.tar.zst" >/dev/null; then
  echo 'FAIL: consumer of a failed prerequisite was built' >&2
  exit 1
fi
printf 'PASS: failed prerequisite blocks consumers; independent build remains clean\n'

# A later job can resolve dependencies from artifacts kept by the caller.
# Make consumer depend on the already staged fixture without selecting it.
sed -i "s/^checkdepends_.*/depends=('independent')/" "$TEST_ROOT/pkgbuilds/consumer/PKGBUILD"
OMARCHY_KEEP_BUILD_WORKSPACE=1 run_build consumer > "$TEST_ROOT/seeded.log" 2>&1 || {
  cat "$TEST_ROOT/seeded.log"
  exit 1
}
compgen -G "$TEST_ROOT/build-output/edge/$TEST_ARCH/consumer-1-1-*.pkg.tar.zst" >/dev/null
printf 'PASS: kept workspace supplies dependencies to a later isolated build\n'

# A rebuild may keep its filename while changing its bytes. Pacman's shared
# cache must not hide the replacement artifact from the next consumer.
cat >> "$TEST_ROOT/pkgbuilds/independent/PKGBUILD" <<'EOF'
package() {
  install -Dm644 /dev/null "$pkgdir/usr/share/build-isolation/independent"
  echo replacement > "$pkgdir/usr/share/build-isolation/independent"
}
EOF
cat >> "$TEST_ROOT/pkgbuilds/consumer/PKGBUILD" <<'EOF'
check() { [[ $(cat /usr/share/build-isolation/independent) == replacement ]]; }
EOF
OMARCHY_KEEP_BUILD_WORKSPACE=1 run_build independent consumer > "$TEST_ROOT/rebuilt.log" 2>&1 || {
  cat "$TEST_ROOT/rebuilt.log"
  exit 1
}
printf 'PASS: rebuilt artifacts supersede cached packages with the same filename\n'

# CI's deferred pair mode still accepts the complete request although each
# half now builds in its own container. An unavailable runtime dependency
# proves it was deferred; build/test dependencies still use pacman normally.
sed -i "s/^depends=.*/depends=('omarchy-settings-dev' 'unavailable-runtime-fixture')/" "$TEST_ROOT/pkgbuilds/omarchy-dev/PKGBUILD"
OMARCHY_DEFER_RUNTIME_DEPS=true run_build omarchy-dev omarchy-settings-dev > "$TEST_ROOT/deferred.log" 2>&1 || {
  cat "$TEST_ROOT/deferred.log"
  exit 1
}
compgen -G "$TEST_ROOT/build-output/edge/$TEST_ARCH/omarchy-dev-1-1-*.pkg.tar.zst" >/dev/null
printf 'PASS: deferred pair mode works across isolated containers\n'

fixture excluded ''
printf '{"source":"local","channels":["stable"]}\n' > "$TEST_ROOT/pkgbuilds/excluded/.omarchy/package.json"
run_build excluded > "$TEST_ROOT/empty.log" 2>&1 || { cat "$TEST_ROOT/empty.log"; exit 1; }
grep -q 'Total packages: 0' "$TEST_ROOT/empty.log"
if grep -q 'in a fresh container' "$TEST_ROOT/empty.log"; then
  echo 'FAIL: an excluded package started a build container' >&2
  exit 1
fi
printf 'PASS: empty plans finish without starting a package build\n'
