#!/bin/bash
# Capture setup_qemu's Docker command without running a container.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
CALLS_FILE=$(mktemp)
EXPECTED_FILE=$(mktemp)
trap 'rm -f "$CALLS_FILE" "$EXPECTED_FILE"' EXIT

CONTAINER_ENGINE=docker
source "$ROOT/helpers/docker-helpers.sh"

docker() {
  printf '%s\n' "$@" >> "$CALLS_FILE"
  return "$DOCKER_STATUS"
}
print_success() { :; }
print_error() { :; }

image=docker.io/tonistiigi/binfmt:qemu-v10.2.3-68@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0
for arch in aarch64 x86_64; do
  case "$arch" in
    aarch64) platform=arm64 ;;
    x86_64) platform=amd64 ;;
  esac
  printf '%s\n' run --rm --privileged "$image" --uninstall "qemu-$arch" --install "$platform" > "$EXPECTED_FILE"
  for DOCKER_STATUS in 0 1; do
    : > "$CALLS_FILE"
    if (setup_qemu "$arch"); then
      result=0
    else
      result=$?
    fi
    [[ $result == "$DOCKER_STATUS" ]] || { echo "FAIL: $arch exit status $result (expected $DOCKER_STATUS)" >&2; exit 1; }
    diff -u "$EXPECTED_FILE" "$CALLS_FILE"
  done
done

# The cloud-init registration must use the same reviewed reference and arguments.
ci_command="  - docker run --rm --privileged $image --uninstall qemu-aarch64 --install arm64 || true"
[[ $(grep -c 'docker.io/tonistiigi/binfmt:' "$ROOT/ci/runner-cloud-init.yaml") == 1 ]]
grep -F -x -q -- "$ci_command" "$ROOT/ci/runner-cloud-init.yaml"
echo 'PASS: pinned QEMU command, failure behavior, and cloud-init reference'
