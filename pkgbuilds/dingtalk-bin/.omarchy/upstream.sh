#!/bin/bash
# DingTalk's download page sends each architecture to its current deb with a
# 302 that only answers GET, and publishes no checksum, so this reads the
# redirect without following it and hashes a new release's debs itself.
set -euo pipefail

declare -A DEB_ARCHES=([x86_64]=amd64 [aarch64]=arm64)
RELEASES="https://dtapp-pub.dingtalk.com/dingtalk-desktop/xc_dingtalk_update/linux_deb/Release"
VERSION='[0-9]{1,4}(\.[0-9]{1,12}){2,4}'

current=$(sed -n 's/^pkgver=//p' PKGBUILD)
versions=()
declare -A urls=()

for arch in "${!DEB_ARCHES[@]}"; do
  deb_arch=${DEB_ARCHES[$arch]}
  location=$(curl --proto =https -fsS --max-time 60 --retry 2 -o /dev/null -w '%{redirect_url}' \
    "https://www.dingtalk.com/win/d/qd=linux_${deb_arch}")
  if [[ ! $location =~ ^${RELEASES//./\\.}/com\.alibabainc\.dingtalk_(${VERSION})_${deb_arch}\.deb$ ]]; then
    echo "Unexpected DingTalk download for $arch: ${location:-no redirect}" >&2
    exit 1
  fi
  versions+=("${BASH_REMATCH[1]}")
  urls[$arch]=$location
done

for version in "${versions[@]}"; do
  if [[ $version != "${versions[0]}" ]]; then
    echo "Upstream architectures are mid-release (${versions[*]}); skipping" >&2
    echo '{}'
    exit 0
  fi
done

# Each release is a 375 MB download per architecture; fetch only a newer one.
if (( $(vercmp "${versions[0]}" "$current") <= 0 )); then
  echo '{}'
  exit 0
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
declare -A checksums=()
for arch in "${!urls[@]}"; do
  deb="$scratch/$arch.deb"
  md5=$(curl --proto =https --proto-redir =https -fsSL --max-time 1800 --retry 2 --max-filesize 1073741824 \
    -o "$deb" -w '%header{content-md5}' "${urls[$arch]}")
  # The bucket's Content-MD5 only proves the download is the object it stores.
  if [[ -z $md5 || $md5 != "$(openssl md5 -binary "$deb" | base64)" ]]; then
    echo "DingTalk $arch deb does not match the bucket's Content-MD5" >&2
    exit 1
  fi
  # The filename is the vendor's claim; the control file is what the deb is.
  control=$(bsdtar -xOf "$deb" 'control.tar.*' | bsdtar -xOf - ./control)
  field() { grep -E "^$1: " <<<"$control" | sed "s/^$1: //"; }
  if [[ $(field Package) != com.alibabainc.dingtalk || $(field Version) != "${versions[0]}" ||
        $(field Architecture) != "${DEB_ARCHES[$arch]}" ]]; then
    echo "DingTalk $arch deb's control file does not describe ${versions[0]} for ${DEB_ARCHES[$arch]}" >&2
    exit 1
  fi
  checksums[$arch]=$(sha256sum "$deb" | cut -d' ' -f1)
done

jq -n \
  --arg pkgver "${versions[0]}" \
  --arg x86_64 "${checksums[x86_64]}" \
  --arg aarch64 "${checksums[aarch64]}" \
  '{pkgver: $pkgver, sha256sums: {x86_64: [$x86_64], aarch64: [$aarch64]}}'
