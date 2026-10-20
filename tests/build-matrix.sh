#!/bin/bash
# Self-test for the runner each build gets (package_runner, and the "runner"
# field bin/build-matrix puts on every entry): aarch64 kernels on the large
# arm64 machine, everything else where it was.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
BUILD_ROOT="$ROOT"
source "$ROOT/helpers/paths.sh"
source "$ROOT/helpers/package-metadata.sh"
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

DROPLET='["self-hosted","omarchy-builder"]'
GITHUB_ARM='["ubuntu-24.04-arm"]'
KERNEL_ARM='["namespace-profile-arm64-linux-apple-12x32"]'

check() {
  local want="$1" name="$2" arch="$3" got
  got=$(package_runner "$name" "$arch")
  [[ $got == "$want" ]] || fail "$name on $arch builds on $got, expected $want"
}

for kernel in linux-omarchy-n1x linux-n1x linux-aurora linux-omarchy; do
  check "$KERNEL_ARM" "$kernel" aarch64
done
pass "an aarch64 kernel builds on the Apple-backed runner at Namespace"

for kernel in linux-omarchy linux-omarchy-bore linux-omarchy-eevdf; do
  check "$DROPLET" "$kernel" x86_64
done
pass "an x86_64 kernel stays on the droplet pool"

check "$GITHUB_ARM" linux-aarch64-pkgbase-shim aarch64
check "$GITHUB_ARM" linux-firmware-cirrus-dx13260 aarch64
pass "a linux-* package that is no kernel stays on GitHub's arm64 runner"

for package in omarchy-settings gliff hyprland nvidia-open-dkms alinux; do
  check "$GITHUB_ARM" "$package" aarch64
  check "$DROPLET" "$package" x86_64
done
pass "every other package builds where it did"

# Each value has to be what runs-on takes: a JSON list of labels.
for runner in "$DROPLET" "$GITHUB_ARM" "$KERNEL_ARM"; do
  jq -e 'type == "array" and length > 0 and all(type == "string")' <<<"$runner" >/dev/null || fail "not a list of labels: $runner"
done
pass "every runner is a JSON list of labels"

# The matrix carries the rule: every entry names its runner, and it is the
# one package_runner gives for that package and architecture.
matrix=$("$ROOT/bin/build-matrix" linux-aurora linux-aarch64-pkgbase-shim omarchy-settings)
[[ $(jq '.include | length' <<<"$matrix") -ge 4 ]] || fail "matrix: $matrix"
while read -r package arch runner; do
  [[ $runner == "$(package_runner "$package" "$arch")" ]] || fail "matrix entry $package $arch has runner $runner"
done < <(jq -r '.include[] | "\(.package) \(.arch) \(.runner)"' <<<"$matrix")
[[ $(jq -r '.include[] | select(.package == "linux-aurora") | .runner' <<<"$matrix") == "$KERNEL_ARM" ]] || fail "linux-aurora in the matrix: $matrix"
pass "bin/build-matrix puts the runner on every entry"
