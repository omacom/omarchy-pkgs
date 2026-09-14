#!/bin/bash
# Cursor publishes Grok Bot through the linux-x64 sand update feed. The feed
# carries version plus the 40-char build id that the Linux .deb URL needs.
# Darwin's feed no longer embeds that id, so this hook reads Linux directly.
#
# bin/sync-upstream rewrites pkgver and sha256sums_x86_64. The Linux URL also
# needs _commit, which that rewriter does not touch, so this hook updates
# _commit itself when it reports a new release.
set -euo pipefail

FEED='https://api2.cursor.sh/updates/api/update/linux-x64/sand/0.0.0/00000000-0000-0000-0000-000000000000/stable'
PKGBUILD="${PKGBUILD:-PKGBUILD}"

if ! command -v vercmp >/dev/null 2>&1; then
  echo "vercmp not found: this hook needs pacman to compare versions" >&2
  exit 1
fi

[[ -f "${PKGBUILD}" ]] || {
  echo "PKGBUILD not found at ${PKGBUILD}" >&2
  exit 1
}

json=$(curl -fsSL -H 'cache-control: no-cache' "${FEED}")
version=$(jq -er '.version // .productVersion // .name' <<<"${json}")
feed_url=$(jq -er '.url' <<<"${json}")
commit=$(sed -nE 's@.*/grokbot/stable/([0-9a-f]{40})/.*@\1@p' <<<"${feed_url}")

[[ -n "${version}" && -n "${commit}" ]] || {
  echo "Could not parse version/commit from linux-x64 sand feed: ${json}" >&2
  exit 1
}

current=$(awk -F= '/^pkgver=/ { print $2; exit }' "${PKGBUILD}" | tr -d "\"'")
if [[ -n "${current}" ]] && [[ "$(vercmp "${version}" "${current}")" -le 0 ]]; then
  echo '{}'
  exit 0
fi

deb_url="https://downloads.cursor.com/grokbot/stable/${commit}/linux/x64/grok-bot_${version}_amd64.deb"
code=$(curl -fsSIL -o /dev/null -w '%{http_code}' "${deb_url}")
[[ "${code}" == "200" ]] || {
  echo "Linux deb not fetchable (${code}): ${deb_url}" >&2
  exit 1
}

sha256=$(curl -fL --retry 3 -sS "${deb_url}" | sha256sum | awk '{print $1}')
[[ "${sha256}" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Could not hash ${deb_url}" >&2
  exit 1
}

if [[ $(grep -c '^_commit=' "${PKGBUILD}") -ne 1 ]]; then
  echo "Expected exactly one _commit= assignment in ${PKGBUILD}" >&2
  exit 1
fi
sed -i "s/^_commit=.*/_commit=${commit}/" "${PKGBUILD}"

jq -n --arg pkgver "${version}" --arg sha256 "${sha256}" \
  '{pkgver: $pkgver, sha256sums: {x86_64: [$sha256]}}'
