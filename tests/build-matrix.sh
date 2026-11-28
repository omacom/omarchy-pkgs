#!/bin/bash
# Self-test for the runner each build gets (package_runner, and the "runner"
# field bin/build-matrix puts on every entry): aarch64 kernels on the large
# arm64 machine, chromium* on the large droplet pool for both architectures
# (aarch64 cross-compiles there, package_build_host), everything else where
# it was.
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
LARGE='["self-hosted","omarchy-builder-large"]'

check() {
  local want="$1" name="$2" arch="$3" got
  got=$(package_runner "$name" "$arch")
  [[ $got == "$want" ]] || fail "$name on $arch builds on $got, expected $want"
}

for kernel in linux-omarchy-aarch64 linux-aurora linux-omarchy; do
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

check "$LARGE" chromium x86_64
check "$LARGE" chromium aarch64
check "$DROPLET" omarchy-chromium-bin x86_64
pass "chromium builds on the large droplet pool for both architectures, and only chromium*"

[[ $(package_build_host chromium aarch64) == x86_64 ]] || fail "chromium for aarch64 builds on $(package_build_host chromium aarch64)"
[[ $(package_build_host chromium x86_64) == x86_64 ]] || fail "chromium for x86_64 builds on $(package_build_host chromium x86_64)"
for package in omarchy-settings hyprland linux-aurora chromium-widevine; do
  [[ $(package_build_host "$package" aarch64) == aarch64 ]] || fail "$package for aarch64 builds on $(package_build_host "$package" aarch64)"
done
pass "only chromium cross-compiles: its aarch64 build runs on an x86_64 builder"

for package in omarchy-settings gliff hyprland nvidia-open-dkms alinux; do
  check "$GITHUB_ARM" "$package" aarch64
  check "$DROPLET" "$package" x86_64
done
pass "every other package builds where it did"

# Each value has to be what runs-on takes: a JSON list of labels.
for runner in "$DROPLET" "$GITHUB_ARM" "$KERNEL_ARM" "$LARGE"; do
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

# Every entry names the builder image it runs in: its own architecture, or
# the cross builder package_build_host gives.
while read -r package arch builder; do
  [[ $builder == "$(package_build_host "$package" "$arch")" ]] || fail "matrix entry $package $arch has builder_arch $builder"
done < <(jq -r '.include[] | "\(.package) \(.arch) \(.builder_arch)"' <<<"$matrix")
pass "bin/build-matrix puts the builder architecture on every entry"

# The cross-build entry itself, from a copy of the tooling whose pkgbuilds/
# holds a chromium that builds for both architectures.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/root/bin"
cp -r "$ROOT/helpers" "$T/root/"
cp "$ROOT/bin/build-matrix" "$T/root/bin/"
for dir in chromium plain-tool; do
  mkdir -p "$T/root/pkgbuilds/$dir/.omarchy"
  printf 'pkgname=%s\narch=(x86_64 aarch64)\n' "$dir" > "$T/root/pkgbuilds/$dir/PKGBUILD"
  echo '{"source": "local", "release_ring": "fast"}' > "$T/root/pkgbuilds/$dir/.omarchy/package.json"
done
matrix=$("$T/root/bin/build-matrix" chromium plain-tool)
entry() { jq -c --arg p "$1" --arg a "$2" '.include[] | select(.package == $p and .arch == $a) | {builder_arch, runner}' <<<"$matrix"; }
[[ $(entry chromium aarch64) == "$(jq -nc --arg r "$LARGE" '{builder_arch: "x86_64", runner: $r}')" ]] || fail "chromium aarch64 entry: $(entry chromium aarch64)"
[[ $(entry chromium x86_64) == "$(jq -nc --arg r "$LARGE" '{builder_arch: "x86_64", runner: $r}')" ]] || fail "chromium x86_64 entry: $(entry chromium x86_64)"
[[ $(entry plain-tool aarch64) == "$(jq -nc --arg r "$GITHUB_ARM" '{builder_arch: "aarch64", runner: $r}')" ]] || fail "plain-tool aarch64 entry: $(entry plain-tool aarch64)"
pass "bin/build-matrix gives chromium's aarch64 entry the x86_64 builder and the large pool"

# Repeated package selections are deduplicated instead of failing metadata loading.
dup_matrix=$("$ROOT/bin/build-matrix" omarchy-settings omarchy-settings)
single_matrix=$("$ROOT/bin/build-matrix" omarchy-settings)
[[ "$dup_matrix" == "$single_matrix" ]] || fail "repeated package names changed matrix: $dup_matrix vs $single_matrix"
stdin_dup_matrix=$(printf "omarchy-settings\nomarchy-settings\n" | "$ROOT/bin/build-matrix")
[[ "$stdin_dup_matrix" == "$single_matrix" ]] || fail "repeated stdin package names changed matrix: $stdin_dup_matrix vs $single_matrix"
pass "bin/build-matrix deduplicates repeated package arguments"
