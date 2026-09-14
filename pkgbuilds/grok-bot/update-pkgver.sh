#!/usr/bin/env bash
# Resolve current Grok Bot stable from Cursor's update feed and pin PKGBUILD.
#
# Prefer the linux-x64 / linux-arm64 sand feeds: they include the 40-char
# build id in the artifact URL. Darwin feeds currently publish a versioned
# zip without that commit, so they cannot locate the Linux .deb.
#
# Deb filenames changed at 0.30.0:
#   linux/x64/grok-bot_${ver}_amd64.deb
#   linux/arm64/grok-bot_${ver}_arm64.deb
# Older builds used Grok_Bot_${ver}.deb on both arches. HEAD-check new names
# first, then the old name, and fail loudly if neither exists.
set -euo pipefail

PKGBUILD_PATH="${1:-PKGBUILD}"
[[ -f "${PKGBUILD_PATH}" ]] || { echo "Error: PKGBUILD not found at '${PKGBUILD_PATH}'" >&2; exit 1; }

MACHINE_ID='00000000-0000-0000-0000-000000000000'
FEED_LINUX_X64="https://api2.cursor.sh/updates/api/update/linux-x64/sand/0.0.0/${MACHINE_ID}/stable"
FEED_LINUX_ARM64="https://api2.cursor.sh/updates/api/update/linux-arm64/sand/0.0.0/${MACHINE_ID}/stable"
FEED_DARWIN="https://api2.cursor.sh/updates/api/update/darwin-arm64/sand/0.0.0/${MACHINE_ID}/stable"

http_code() {
  curl -fsSIL -o /dev/null -w '%{http_code}' "$1" || true
}

parse_commit() {
  sed -nE 's@.*/(grokbot|sand)/stable/([0-9a-f]{40})/.*@\2@p' <<<"$1"
}

fetch_feed() {
  curl -fsSL -H 'cache-control: no-cache' "$1"
}

json="$(fetch_feed "${FEED_LINUX_X64}" || true)"
ver=""
feed_url=""
commit=""
if [[ -n "${json}" ]]; then
  ver="$(jq -er '.name // .version // .productVersion' <<<"${json}" 2>/dev/null || true)"
  feed_url="$(jq -er '.url' <<<"${json}" 2>/dev/null || true)"
  commit="$(parse_commit "${feed_url}")"
fi

if [[ -z "${ver}" || -n "${ver}" && -z "${commit}" ]]; then
  json="$(fetch_feed "${FEED_LINUX_ARM64}" || true)"
  if [[ -n "${json}" ]]; then
    ver="$(jq -er '.name // .version // .productVersion' <<<"${json}")"
    feed_url="$(jq -er '.url' <<<"${json}")"
    commit="$(parse_commit "${feed_url}")"
  fi
fi

if [[ -z "${ver}" || -z "${commit}" ]]; then
  json="$(fetch_feed "${FEED_DARWIN}")"
  ver="$(jq -er '.name // .version' <<<"${json}")"
  feed_url="$(jq -er '.url' <<<"${json}")"
  commit="$(parse_commit "${feed_url}")"
fi

[[ -n "${ver}" && -n "${commit}" ]] || {
  echo "Error: could not parse version/commit from feeds" >&2
  echo "${json}" >&2
  exit 1
}

resolve_deb() {
  local arch_dir="$1" new_name="$2" old_name="$3"
  local base="https://downloads.cursor.com/grokbot/stable/${commit}/linux/${arch_dir}"
  local new_url="${base}/${new_name}"
  local old_url="${base}/${old_name}"
  local code

  code="$(http_code "${new_url}")"
  if [[ "${code}" == "200" ]]; then
    printf '%s\n' "${new_url}"
    return 0
  fi
  code="$(http_code "${old_url}")"
  if [[ "${code}" == "200" ]]; then
    printf '%s\n' "${old_url}"
    return 0
  fi
  echo "Error: Linux ${arch_dir} deb not fetchable (new=${new_url} old=${old_url})" >&2
  return 1
}

deb_x64="$(resolve_deb x64 "grok-bot_${ver}_amd64.deb" "Grok_Bot_${ver}.deb")"
deb_arm64="$(resolve_deb arm64 "grok-bot_${ver}_arm64.deb" "Grok_Bot_${ver}.deb")"

hash_url() {
  local tmp
  tmp="$(mktemp)"
  curl -fL --retry 3 -o "${tmp}" "$1"
  sha256sum "${tmp}" | awk '{print $1}'
  rm -f "${tmp}"
}

sum_x64="$(hash_url "${deb_x64}")"
sum_arm64="$(hash_url "${deb_arm64}")"

current_ver="$(sed -nE 's/^pkgver=([^[:space:]#]+).*/\1/p' "${PKGBUILD_PATH}" | head -n1)"

deb_x64_file="$(basename "${deb_x64}")"
deb_arm64_file="$(basename "${deb_arm64}")"

python3 - "${PKGBUILD_PATH}" "${commit}" "${ver}" "${deb_x64_file}" "${deb_arm64_file}" "${sum_x64}" "${sum_arm64}" <<'PY'
import pathlib, re, sys

path, commit, ver, deb_x64, deb_arm64, sum_x64, sum_arm64 = sys.argv[1:]
text = pathlib.Path(path).read_text()

def sub(pattern, repl, count=1):
    global text
    text, n = re.subn(pattern, repl, text, count=count, flags=re.M)
    if n != count:
        raise SystemExit(f"failed to rewrite {pattern!r} ({n} matches, wanted {count})")

sub(r"^_commit=.*", f"_commit={commit}")
sub(r"^pkgver=.*", f"pkgver={ver}")
sub(r'^_deb_x86_64=.*', f'_deb_x86_64="{deb_x64}"')
sub(r'^_deb_aarch64=.*', f'_deb_aarch64="{deb_arm64}"')
sub(r"^sha256sums_x86_64=.*", f"sha256sums_x86_64=('{sum_x64}')")
sub(r"^sha256sums_aarch64=.*", f"sha256sums_aarch64=('{sum_arm64}')")
pathlib.Path(path).write_text(text)
PY

if [[ "${ver}" != "${current_ver}" ]]; then
  sed -i -E 's/^pkgrel=.*/pkgrel=1/' "${PKGBUILD_PATH}"
fi

echo "${ver} ${commit}"
echo "${deb_x64}"
echo "${sum_x64}"
echo "${deb_arm64}"
echo "${sum_arm64}"
