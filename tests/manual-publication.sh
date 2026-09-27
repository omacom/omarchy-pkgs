#!/bin/bash
# Real-container manual admission through local publication. Run as an ordinary
# Docker-enabled user; TEST_BUILDER_IMAGE is built from build-isolation.Dockerfile.
set -euo pipefail

BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
source "$BUILD_ROOT/helpers/message-helpers.sh"
source "$BUILD_ROOT/helpers/docker-helpers.sh"
check_engine
[[ $CONTAINER_ENGINE == "docker" ]] || { echo 'This fixture requires Docker' >&2; exit 1; }
(( EUID != 0 )) || { echo 'Run this fixture as an ordinary user' >&2; exit 1; }
TEST_ARCH=$(docker_native_arch)
TEST_BUILDER_IMAGE=${TEST_BUILDER_IMAGE:-omarchy-build-isolation-test}
TEST_ENGINE=$(command -v docker)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
chmod 755 "$TEST_ROOT"

# Keep every command's rooted paths real. The checkout below has no forwarding
# config or credentials; the only sync destination is its disposable local dir.
mkdir -p "$TEST_ROOT/"{bin,build-output/edge/$TEST_ARCH,engine,pkgbuilds/splitjob/.omarchy,remote/edge/$TEST_ARCH}
cp "$BUILD_ROOT/bin/"{upload-prebuilt,repo,sign,promote-build,update-repo,sync-repo} "$TEST_ROOT/bin/"
cp -r "$BUILD_ROOT/build" "$BUILD_ROOT/helpers" "$TEST_ROOT/"
printf '%s\n' '{"source":"local","artifacts":{"pkgbase":"splitjob","packages":["alpha","beta"]}}' \
  > "$TEST_ROOT/pkgbuilds/splitjob/.omarchy/package.json"
[[ ! -e "$TEST_ROOT/.publication/edge/$TEST_ARCH/manifest.json" ]]

# Map normal utility-image tags to the supplied test image, without building
# or changing any operator image. No container in this fixture needs network.
cat > "$TEST_ROOT/engine/docker" <<'ENGINE'
#!/bin/bash
args=("$@")
[[ ${args[0]} != buildx ]] || exit 0
if [[ ${args[0]} == run ]]; then
  args=(run --network none "${args[@]:1}")
fi
for index in "${!args[@]}"; do
  if [[ ${args[$index]} == omarchy-pkg-builder:latest-* ]]; then
    args[$index]=$TEST_BUILDER_IMAGE
  fi
done
exec "$TEST_ENGINE" "${args[@]}"
ENGINE
cat > "$TEST_ROOT/engine/rclone" <<'RCLONE'
#!/bin/bash
exec "$TEST_ENGINE" run --rm --network none --user "$(id -u):$(id -g)" \
  -v "$TEST_ROOT:$TEST_ROOT" "$TEST_BUILDER_IMAGE" \
  rclone --config /dev/null "$@"
RCLONE
# update-repo's Docker permission helper tries sudo chown, then chmod. The
# caller owns the temporary tree, so its chmod fallback works without sudo.
cat > "$TEST_ROOT/engine/sudo" <<'SUDO'
#!/bin/bash
exit 1
SUDO
chmod +x "$TEST_ROOT/engine/"*
export TEST_ROOT TEST_ENGINE TEST_BUILDER_IMAGE
export PATH="$TEST_ROOT/engine:$PATH"
unset OMARCHY_REPO_HOST OMARCHY_REPO_ROOT OMARCHY_RELEASE_LOCK_HELD
unset GPG_PASSPHRASE GPG_PRIVATE_KEY

run_tool() {
  "$TEST_ENGINE" run --rm -i --network none --user "$(id -u):$(id -g)" \
    -v "$TEST_ROOT:$TEST_ROOT" "$TEST_BUILDER_IMAGE" "$@"
}

# Data-only packages with the normal repo-add identity fields. Both archives
# come from one reviewed split job and contain no executable payload.
run_tool python3 - "$TEST_ROOT/build-output/edge/$TEST_ARCH" "$TEST_ARCH" <<'PY'
import io
from pathlib import Path
import subprocess
import sys
import tarfile

output, arch = Path(sys.argv[1]), sys.argv[2]
for name in ('alpha', 'beta'):
    info = (f'pkgname = {name}\npkgbase = splitjob\npkgver = 1-1\n'
            f'arch = {arch}\npkgdesc = Publication fixture\n'
            'url = https://example.invalid/fixture\nbuilddate = 1\n'
            'packager = Test Fixture <fixture@test.invalid>\nsize = 0\n'
            'license = MIT\n').encode()
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w') as archive:
        entry = tarfile.TarInfo('.PKGINFO')
        entry.size = len(info)
        archive.addfile(entry, io.BytesIO(info))
    with (output / f'{name}-1-1-{arch}.pkg.tar.zst').open('wb') as dest:
        subprocess.run(['zstd', '-q', '-c'], input=data.getvalue(), stdout=dest, check=True)
PY

KEYHOME="$TEST_ROOT/keyhome"
mkdir -m700 "$KEYHOME"
run_tool env GNUPGHOME="$KEYHOME" bash -c '
  set -e
  gpg --batch --quiet --pinentry-mode loopback --passphrase "" \
    --quick-gen-key "Publication Fixture <fixture@test.invalid>" ed25519 sign 0
  gpg --batch --quiet --export > "$1/signing-key.gpg"
  gpg --batch --quiet --armor --export-secret-keys > "$1/private.asc"
' bash "$TEST_ROOT"
export GPG_PRIVATE_KEY
GPG_PRIVATE_KEY=$(cat "$TEST_ROOT/private.asc")
export GPG_PASSPHRASE=''

if ! "$TEST_ROOT/bin/upload-prebuilt" --arch "$TEST_ARCH" --mirror edge \
    --package splitjob --remote "$TEST_ROOT/remote" > "$TEST_ROOT/upload.log" 2>&1; then
  cat "$TEST_ROOT/upload.log" >&2
  exit 1
fi

repo="$TEST_ROOT/remote/edge/$TEST_ARCH"
for name in alpha beta; do
  file="$name-1-1-$TEST_ARCH.pkg.tar.zst"
  [[ -s "$repo/$file" && -s "$repo/$file.sig" ]]
  run_tool env GNUPGHOME="$KEYHOME" gpgv --keyring "$TEST_ROOT/signing-key.gpg" \
    "$repo/$file.sig" "$repo/$file" >/dev/null
  [[ ! -e "$TEST_ROOT/build-output/edge/$TEST_ARCH/$file" ]]
done
[[ -s "$repo/omarchy.db" ]]
db_listing=$(run_tool bsdtar -tf "$repo/omarchy.db")
[[ $db_listing == *alpha-1-1/* && $db_listing == *beta-1-1/* ]]
[[ ! -e "$TEST_ROOT/.publication/edge/$TEST_ARCH/manifest.json" ]]
[[ ! -e "$TEST_ROOT/.publication/edge/$TEST_ARCH/manifest.json.sig" ]]
echo 'PASS: manual split-job upload signed and published both outputs to a local rclone directory'
