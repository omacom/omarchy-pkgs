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

# bin/build mount isolation and failure meson-log export (offline, fake engine).
BT="$T/bin-build"
mkdir -p "$BT/bin" "$BT/pkgbuilds/alpha/.omarchy" "$BT/pkgbuilds/beta/.omarchy" "$BT/fake-bin" "$BT/results" "$BT/src/beta"
echo keep > "$BT/src/beta/existing-tree-marker"
mkdir -p "$BT/src/test-logs/edge/$(uname -m | sed 's/^arm64$/aarch64/')/alpha"
echo stale > "$BT/src/test-logs/edge/$(uname -m | sed 's/^arm64$/aarch64/')/alpha/stale.txt"
cp "$ROOT/bin/build" "$BT/bin/"
cp -r "$ROOT/helpers" "$ROOT/build" "$BT/"
for pkg in alpha beta; do
  printf '{"source":"local"}\n' > "$BT/pkgbuilds/$pkg/.omarchy/package.json"
  printf 'pkgname=%s\npkgver=1\npkgrel=1\narch=(x86_64 aarch64)\n' "$pkg" > "$BT/pkgbuilds/$pkg/PKGBUILD"
done

cat > "$BT/fake-bin/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  info) exit 0 ;;
  image) [[ "${2:-}" == "inspect" ]] && exit 0 ;;
  run) shift ;;
  *) exit 0 ;;
esac

dry_run="" build_pkg="" workdir="" plan_host="" pkg_ro="" dep_ro="" out_host="" log_host="" cache_host="" src_tmpfs=""
bad_mount=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e)
      case "$2" in
        DRY_RUN=*) dry_run="${2#DRY_RUN=}" ;;
        BUILD_PACKAGE=*) build_pkg="${2#BUILD_PACKAGE=}" ;;
      esac
      shift 2
      ;;
    -w) workdir="$2"; shift 2 ;;
    -v)
      host="${2%%:*}" target="${2#*:}"
      case "$target" in
        /build-plan) plan_host="$host" ;;
        /build-plan/packages:ro) pkg_ro="$host" ;;
        /build-plan/dependencies:ro) dep_ro="$host" ;;
        "/build-output/edge/$FAKE_ARCH") out_host="$host" ;;
        /src-export) log_host="$host" ;;
        /var/cache/pacman/pkg) cache_host="$host" ;;
        /build-output|/build-output:ro|/build-output/*|/src|/src:*) bad_mount="$2" ;;
      esac
      shift 2
      ;;
    --tmpfs)
      [[ "$2" == /src:* ]] && src_tmpfs="$2"
      shift 2
      ;;
    omarchy-pkg-builder:*) shift; break ;;
    *) shift ;;
  esac
done

fail_call() { echo "ASSERTION_FAIL: $1" >> "$FAKE_DOCKER_LOG"; exit 9; }
[[ -z "$bad_mount" ]] || fail_call "disallowed mount ($build_pkg): $bad_mount"

if [[ "$dry_run" == "true" ]]; then
  [[ "$workdir" == "/tmp" ]] || fail_call "planning workdir was '$workdir', expected /tmp"
  [[ -n "$plan_host" && "$plan_host" != "$FAKE_BT/src/"* ]] || fail_call "bad planning dir: $plan_host"
  [[ -z "$out_host" && -z "$log_host" && -z "$cache_host" && -z "$src_tmpfs" ]] || fail_call "planning mounted output, cache, src-export, or /src tmpfs"
  printf '%s\n' "$plan_host" > "$FAKE_BT/plan-dir"
  printf 'alpha\nbeta\n' > "$plan_host/packages"
  : > "$plan_host/dependencies"
  : > "$plan_host/skipped"
  echo "PLAN_OK" >> "$FAKE_DOCKER_LOG"
  exit 0
fi

root_plan=$(cat "$FAKE_BT/plan-dir")
[[ "$out_host" == "$FAKE_BT/build-output/edge/$FAKE_ARCH" ]] || fail_call "wrong output mount for $build_pkg: $out_host"
[[ "$plan_host" == "$root_plan/run."* ]] || fail_call "non-isolated /build-plan for $build_pkg: $plan_host"
[[ "$pkg_ro" == "$root_plan/packages" && "$dep_ro" == "$root_plan/dependencies" ]] || fail_call "missing :ro plan files for $build_pkg"
[[ "$log_host" == "$root_plan/logs."* ]] || fail_call "non-isolated /src-export for $build_pkg: $log_host"
[[ "$*" == *meson-logs* ]] || fail_call "missing meson-logs export wrapper for $build_pkg"

if [[ "$build_pkg" == "alpha" ]]; then
  [[ ! -e "$plan_host/repository-initialized" ]] || fail_call "unexpected repository-initialized before alpha"
  touch "$plan_host/repository-initialized"
  mkdir -p "$plan_host/artifacts"
  printf 'alpha-1-1-%s.pkg.tar.zst\n' "$FAKE_ARCH" > "$plan_host/artifacts/alpha"
  echo "ALPHA_OK" >> "$FAKE_DOCKER_LOG"
  exit 0
fi

if [[ "$build_pkg" == "beta" ]]; then
  [[ -e "$plan_host/repository-initialized" ]] || fail_call "missing repository-initialized on beta"
  [[ ! -e "$plan_host/artifacts/alpha" ]] || fail_call "alpha artifact manifest leaked into beta"
  mkdir -p "$log_host/beta/build/meson-logs"
  printf 'failed assertion\n' > "$log_host/beta/build/meson-logs/testlog.txt"
  echo "BETA_OK" >> "$FAKE_DOCKER_LOG"
  exit 1
fi
FAKE
chmod +x "$BT/fake-bin/docker"

native_arch=$(uname -m)
[[ "$native_arch" == "arm64" ]] && native_arch=aarch64
bt_rc=0
PATH="$BT/fake-bin:$PATH" \
  CONTAINER_ENGINE=docker \
  OMARCHY_SKIP_BUILDER_IMAGE=1 \
  OMARCHY_BUILD_RESULT_DIR="$BT/results" \
  FAKE_DOCKER_LOG="$BT/docker.log" \
  FAKE_BT="$BT" \
  FAKE_ARCH="$native_arch" \
  "$BT/bin/build" --arch "$native_arch" --mirror edge --package alpha beta > "$BT/build.log" 2>&1 || bt_rc=$?

if [[ "$bt_rc" != 2 ]] || grep -q '^ASSERTION_FAIL:' "$BT/docker.log" \
  || ! grep -qx 'PLAN_OK' "$BT/docker.log" \
  || ! grep -qx 'ALPHA_OK' "$BT/docker.log" \
  || ! grep -qx 'BETA_OK' "$BT/docker.log"; then
  cat "$BT/build.log"
  cat "$BT/docker.log" 2>/dev/null || true
  fail "bin/build fake-docker isolation checks failed (rc=$bt_rc)"
fi
[[ "$(cat "$BT/results/artifacts")" == "alpha-1-1-$native_arch.pkg.tar.zst" ]] || fail "artifacts mismatch"
[[ "$(cat "$BT/results/failed")" == "beta" ]] || fail "failed mismatch"
[[ ! -e "$BT/src/test-logs/edge/$native_arch/alpha/stale.txt" ]] || fail "stale meson logs for alpha were not cleared"
[[ "$(cat "$BT/src/test-logs/edge/$native_arch/beta/build/meson-logs/testlog.txt")" == "failed assertion" ]] || fail "exported beta meson log missing"
[[ "$(cat "$BT/src/beta/existing-tree-marker")" == "keep" ]] || fail "meson log export clobbered existing src/beta tree"
pass "bin/build isolates /build-output and /build-plan mounts and exports failed meson-logs cleanly"

# Package-name validation: accept valid recipe directory names and blank stdin;
# reject path traversal, leading dashes/dots, whitespace, and shell syntax.
mkdir -p "$T/root/pkgbuilds/1Pkg@2.0_foo+bar-1/.omarchy"
printf 'pkgname=1pkg@2.0_foo+bar-1\narch=(x86_64)\n' > "$T/root/pkgbuilds/1Pkg@2.0_foo+bar-1/PKGBUILD"
echo '{"source": "local"}' > "$T/root/pkgbuilds/1Pkg@2.0_foo+bar-1/.omarchy/package.json"
[[ $(jq -r '.include[0].package' <<<"$("$T/root/bin/build-matrix" 1Pkg@2.0_foo+bar-1)") == "1Pkg@2.0_foo+bar-1" ]] || fail "valid recipe name rejected"
[[ $("$T/root/bin/build-matrix" <<< $'\n\n') == '{"include":[]}' ]] || fail "blank stdin failed"

# shellcheck disable=SC2016
for bad in "../outside" ".hidden" "-foo" "foo;id" 'foo$(id)' "foo bar"; do
  out=$("$T/root/bin/build-matrix" "$bad" 2>&1) && fail "accepted invalid arg: $bad"
  [[ "$out" == *"invalid package name"* ]] || fail "unexpected error for arg $bad: $out"
  out=$(printf '%s\n' "$bad" | "$T/root/bin/build-matrix" 2>&1) && fail "accepted invalid stdin: $bad"
  [[ "$out" == *"invalid package name"* ]] || fail "unexpected error for stdin $bad: $out"
done
pass "bin/build-matrix validates package names"
