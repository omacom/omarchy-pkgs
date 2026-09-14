#!/usr/bin/env bash
# Resolve current Grok Bot stable from Cursor's update feed and pin PKGBUILD.
# The linux-x64 sand feed publishes version + commit via its AppImage zsync URL;
# the Linux .deb lives at the same commit with a predictable filename.
set -euo pipefail

PKGBUILD_PATH="${1:-PKGBUILD}"
[[ -f "${PKGBUILD_PATH}" ]] || { echo "Error: PKGBUILD not found at '${PKGBUILD_PATH}'" >&2; exit 1; }

FEED='https://api2.cursor.sh/updates/api/update/linux-x64/sand/0.0.0/00000000-0000-0000-0000-000000000000/stable'
json="$(curl -fsSL -H 'cache-control: no-cache' "${FEED}")"

ver="$(jq -er '.version // .name' <<<"${json}")"
feed_url="$(jq -er '.url' <<<"${json}")"
commit="$(sed -nE 's@.*/(grokbot|sand)/stable/([0-9a-f]{40})/.*@\2@p' <<<"${feed_url}")"

[[ -n "${ver}" && -n "${commit}" ]] || {
  echo "Error: could not parse version/commit from feed: ${json}" >&2
  exit 1
}

deb_url="https://downloads.cursor.com/grokbot/stable/${commit}/linux/x64/grok-bot_${ver}_amd64.deb"
code="$(curl -fsSIL -o /dev/null -w '%{http_code}' "${deb_url}")"
[[ "${code}" == "200" ]] || {
  echo "Error: Linux deb not fetchable (${code}): ${deb_url}" >&2
  exit 1
}

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
curl -fL --retry 3 -o "${tmp}" "${deb_url}"
sum="$(sha256sum "${tmp}" | awk '{print $1}')"

current_ver="$(sed -nE 's/^pkgver=([^[:space:]#]+).*/\1/p' "${PKGBUILD_PATH}" | head -n1)"

sed -i -E \
  -e "s/^_commit=.*/_commit=${commit}/" \
  -e "s/^pkgver=.*/pkgver=${ver}/" \
  -e "s/^sha256sums=\\('[0-9a-f]{64}'/sha256sums=('${sum}'/" \
  "${PKGBUILD_PATH}"

if [[ "${ver}" != "${current_ver}" ]]; then
  sed -i -E 's/^pkgrel=.*/pkgrel=1/' "${PKGBUILD_PATH}"
fi

echo "${ver} ${commit}"
echo "${deb_url}"
echo "${sum}"
