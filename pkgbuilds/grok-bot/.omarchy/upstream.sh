#!/bin/bash
# Cursor's apt index lags the Linux build the app updates from. The sand
# update feed is that build: each architecture names a version and a commit,
# and the .deb (not the AppImage the feed links) is published at
# downloads.cursor.com/grokbot/stable/<commit>/. The feed digest is the
# AppImage, so a newer release is hashed from the debs. A run that is already
# current does not download them.
#
# bin/sync-upstream rewrites pkgver and the deb checksums. It does not rewrite
# _commit, which the source URL depends on, so this hook writes that assignment
# and only when the version is actually newer.
set -euo pipefail

declare -A FEED_ARCH=([x86_64]=x64 [aarch64]=arm64)
declare -A DEB_ARCH=([x86_64]=amd64 [aarch64]=arm64)
ARCHES=(x86_64 aarch64)

curl_https() {
  curl --proto '=https' --proto-redir '=https' -fsSL \
    --connect-timeout 20 --retry 2 --retry-all-errors "$@"
}

parse_feed() {
  jq -er '
    (.version | strings) as $version
    | (.url | strings) as $url
    | ($url | capture("grokbot/stable/(?<commit>[0-9a-f]{40})/").commit) as $commit
    | if ($version | test("\\A[0-9]+\\.[0-9]+\\.[0-9]+\\z")) then
        "\($version) \($commit)"
      else
        error("version is not x.y.z")
      end
  '
}

read_assignment() {
  local name="$1" value
  value=$(grep -m1 -E "^${name}=" PKGBUILD | cut -d= -f2- | tr -d "\"'")
  [[ -n "$value" ]] || {
    echo "PKGBUILD has no ${name} assignment" >&2
    return 1
  }
  printf '%s' "$value"
}

current_pkgver=$(read_assignment pkgver)
current_commit=$(read_assignment _commit)

versions=()
commits=()
for arch in "${ARCHES[@]}"; do
  json=$(curl_https --max-time 60 \
    "https://api2.cursor.sh/updates/api/update/linux-${FEED_ARCH[$arch]}/sand/0.0.0/00000000-0000-0000-0000-000000000000/stable")
  if ! parsed=$(parse_feed <<<"$json"); then
    echo "Grok Bot ${arch} feed did not name a version and commit" >&2
    exit 1
  fi
  read -r version commit <<<"$parsed"
  versions+=("$version")
  commits+=("$commit")
done

if [[ "${versions[0]}" != "${versions[1]}" || "${commits[0]}" != "${commits[1]}" ]]; then
  echo "Upstream architectures are mid-release (x86_64 ${versions[0]} ${commits[0]}, aarch64 ${versions[1]} ${commits[1]}); skipping" >&2
  echo '{}'
  exit 0
fi

version="${versions[0]}"
commit="${commits[0]}"

emit() {
  jq -n \
    --arg pkgver "$version" \
    --arg x86_64 "$1" \
    --arg aarch64 "$2" \
    '{pkgver: $pkgver, sha256sums: {x86_64: [$x86_64], aarch64: [$aarch64]}}'
}

# Not an upgrade. sync-upstream ignores the checksums unless the version is newer.
if [[ "$(vercmp "$version" "$current_pkgver")" -le 0 ]]; then
  if [[ "$version" == "$current_pkgver" && "$commit" != "$current_commit" ]]; then
    echo "Grok Bot ${version} was republished at ${commit} (recipe has ${current_commit}); refusing to keep the old debs" >&2
    exit 1
  fi
  eval "$(bash -c 'source ./PKGBUILD >/dev/null; printf "deb_x86_64=%q\ndeb_aarch64=%q\n" "${sha256sums_x86_64[0]}" "${sha256sums_aarch64[0]}"')"
  emit "$deb_x86_64" "$deb_aarch64"
  exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
declare -A checksums=()
for arch in "${ARCHES[@]}"; do
  deb="grok-bot_${version}_${DEB_ARCH[$arch]}.deb"
  url="https://downloads.cursor.com/grokbot/stable/${commit}/linux/${FEED_ARCH[$arch]}/${deb}"
  curl_https --max-time 300 -o "$tmpdir/$deb" "$url"
  checksums[$arch]=$(sha256sum "$tmpdir/$deb" | awk '{print $1}')
  [[ "${checksums[$arch]}" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Bad checksum for Grok Bot ${arch}" >&2
    exit 1
  }
done

python3 - "$commit" <<'PY'
import pathlib, sys
commit = sys.argv[1]
path = pathlib.Path("PKGBUILD")
lines = path.read_text().splitlines(keepends=True)
found = 0
out = []
for line in lines:
    if line.startswith("_commit="):
        found += 1
        newline = "\n" if line.endswith("\n") else ""
        out.append(f"_commit={commit}{newline}")
    else:
        out.append(line)
if found != 1:
    raise SystemExit(f"expected one _commit= assignment, found {found}")
path.write_text("".join(out))
PY

emit "${checksums[x86_64]}" "${checksums[aarch64]}"
