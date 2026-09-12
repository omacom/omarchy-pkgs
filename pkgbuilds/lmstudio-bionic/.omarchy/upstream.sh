#!/bin/bash
# Bionic publishes stable version state and SHA-512 installer sidecars, while
# sync-upstream records SHA-256. Check the version first, then download and
# rehash the installers only when a new release is available.
set -euo pipefail

STATE_URL="https://bionic-updates.lmstudio.ai/updates-active/public.json"
INSTALLER_BASE_URL="https://bionic-installers.lmstudio.ai/linux"

declare -A STATE_ARCHES=([x86_64]=x86 [aarch64]=arm64)
declare -A INSTALLER_ARCHES=([x86_64]=x64 [aarch64]=arm64)
declare -A releases=()

state=$(curl -fsSL "$STATE_URL")
for arch in x86_64 aarch64; do
  release=$(jq -er --arg arch "${STATE_ARCHES[$arch]}" '
    .stable.linux[$arch]
    | select(.sourceChannel == "stable")
    | [.version, .build]
    | @tsv
  ' <<<"$state")
  read -r version build <<<"$release"
  if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! $build =~ ^[0-9A-Za-z.-]+$ ]]; then
    echo "Invalid stable Bionic release for $arch: ${version:-<empty>}+${build:-<empty>}" >&2
    exit 1
  fi
  releases[$arch]="${version}+${build}"
done

# A release can land one architecture at a time. Wait until both installers
# agree so one pkgver never points at artifacts from different releases.
if [[ ${releases[x86_64]} != "${releases[aarch64]}" ]]; then
  echo "Bionic architectures are mid-release (${releases[x86_64]}, ${releases[aarch64]}); skipping" >&2
  echo '{}'
  exit 0
fi

pkgver=${releases[x86_64]}
current=$(grep -m1 '^pkgver=' PKGBUILD | cut -d= -f2- | tr -d "\"'")
if [[ $(vercmp "$pkgver" "$current") -le 0 ]]; then
  echo '{}'
  exit 0
fi

release=${pkgver/+/-}
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
declare -A sha256s=()

for arch in x86_64 aarch64; do
  installer_arch=${INSTALLER_ARCHES[$arch]}
  asset="Bionic-${release}-${installer_arch}.AppImage"
  url="${INSTALLER_BASE_URL}/${installer_arch}/${release}/${asset}"
  expected_sha512=$(curl -fsSL "${url}.sha512" | awk '{ print $1; exit }')
  if [[ ! $expected_sha512 =~ ^[0-9a-f]{128}$ ]]; then
    echo "Invalid SHA-512 sidecar for $asset" >&2
    exit 1
  fi

  curl -fsSL -o "$temp_dir/$asset" "$url"
  actual_sha512=$(sha512sum "$temp_dir/$asset" | awk '{ print $1 }')
  if [[ $actual_sha512 != "$expected_sha512" ]]; then
    echo "$asset does not match its published SHA-512" >&2
    exit 1
  fi
  sha256s[$arch]=$(sha256sum "$temp_dir/$asset" | awk '{ print $1 }')
done

jq -n \
  --arg pkgver "$pkgver" \
  --arg x86_64 "${sha256s[x86_64]}" \
  --arg aarch64 "${sha256s[aarch64]}" \
  '{pkgver: $pkgver, sha256sums: {x86_64: [$x86_64], aarch64: [$aarch64]}}'
