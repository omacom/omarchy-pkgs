#!/bin/bash
# Anthropic ships the Claude desktop app from its own Debian repository, and
# signs that repository's index. Reading the index costs three small HTTP
# requests instead of two half-gigabyte downloads, the pool keeps old versions
# so the URLs pinned in the PKGBUILD stay resolvable after the next release,
# and -- the point of doing it this way -- every checksum that reaches the
# PKGBUILD has been carried there under Anthropic's own signature:
#
#   the bundled key, pinned by fingerprint  ->  signs InRelease
#   InRelease                               ->  hashes Packages
#   Packages                                ->  hashes each .deb
#
# A break anywhere in that chain fails the sync rather than proposing a
# checksum nobody vouched for.
set -euo pipefail

BASE_URL="https://downloads.claude.ai/claude-desktop/apt/stable"
declare -A DEB_ARCHES=([x86_64]=amd64 [aarch64]=arm64)

# "Anthropic Claude Code Release Signing <security@anthropic.com>", the
# trust anchor for everything below. Cross-checked against four independent
# sources: the published install docs, downloads.claude.ai/claude-desktop/
# key.asc, the InRelease signature itself, and the copy embedded in the
# .deb's own postinst. The key is committed next to this hook rather than
# fetched, so rotating it is a reviewed change to this package, not
# something the server can do to us.
KEY_FILE=".omarchy/anthropic-release-signing.key"
KEY_FPR='31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE'

MIN_AGE="${MIN_RELEASE_AGE_SECONDS:-0}"
BYPASS="${BYPASS_MIN_RELEASE_AGE:-}"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  echo "$*" >&2
  exit 1
}

# --- trust anchor -----------------------------------------------------------
GNUPGHOME="$WORK_DIR/gnupg"
export GNUPGHOME
install -dm700 "$GNUPGHOME"

[[ -f "$KEY_FILE" ]] || fail "Signing key missing: $KEY_FILE"
gpg --batch --quiet --import "$KEY_FILE" 2>/dev/null ||
  fail "Could not import $KEY_FILE"

got_fpr=$(gpg --batch --with-colons --fingerprint | awk -F: '/^fpr:/{print $10; exit}')
[[ "$got_fpr" == "$KEY_FPR" ]] ||
  fail "Bundled key is not Anthropic's: got ${got_fpr:-none}, expected $KEY_FPR"

# --- the signed index -------------------------------------------------------
curl -fsSL -o "$WORK_DIR/InRelease" "$BASE_URL/dists/stable/InRelease" ||
  fail "Could not fetch InRelease"

# Written out and read back rather than verified in place: gpg reports a good
# signature on a clearsigned file that carries unsigned text outside the armour.
gpg --batch --yes --output "$WORK_DIR/Release" --decrypt "$WORK_DIR/InRelease" >/dev/null 2>&1 ||
  fail "InRelease is not signed by Anthropic's release key"

# Each architecture's Packages index, authenticated by the hash InRelease
# signs for it. Scoped to the SHA256 block: the same filenames recur under
# SHA512, and taking the first match regardless would compare a SHA256 sum
# against a SHA512 entry.
fetch_packages() {
  local deb_arch="$1" path="main/binary-${1}/Packages"
  local out="$WORK_DIR/Packages.$deb_arch" want got

  want=$(awk -v path="$path" '
    /^SHA256:/                     { in_block = 1; next }
    /^[A-Za-z][A-Za-z0-9-]*:/      { in_block = 0 }
    in_block && $3 == path && length($1) == 64 { print $1; exit }
  ' "$WORK_DIR/Release")
  [[ -n "$want" ]] || fail "InRelease carries no SHA256 for $path"

  curl -fsSL -o "$out" "$BASE_URL/dists/stable/$path" ||
    fail "Could not fetch $path"

  got=$(sha256sum "$out" | cut -d' ' -f1)
  [[ "$got" == "$want" ]] ||
    fail "$path does not match the hash InRelease signs for it"

  echo "$out"
}

# "<version> <sha256>" per stanza, for our package only. The pool is shared,
# and a stanza that carries no checksum must not donate its version to the
# next one, so both fields reset at each Package: head.
releases_in() {
  awk '
    { sub(/\r$/, "") }
    /^Package:/ { pkg = $2; version = sha256 = "" }
    /^Version:/ { version = $2 }
    /^SHA256:/  { sha256 = $2 }
    /^$/        { if (pkg == "claude-desktop" && version && sha256) print version, sha256
                  pkg = version = sha256 = "" }
    END         { if (pkg == "claude-desktop" && version && sha256) print version, sha256 }
  ' "$1"
}

declare -A CHECKSUMS=()   # "<arch> <version>" -> sha256
declare -A SEEN_COUNT=()  # version -> number of arches offering it

for arch in "${!DEB_ARCHES[@]}"; do
  deb_arch="${DEB_ARCHES[$arch]}"
  packages=$(fetch_packages "$deb_arch")

  while read -r version sha256; do
    [[ -n "$version" ]] || continue
    CHECKSUMS["$arch $version"]="$sha256"
    SEEN_COUNT[$version]=$(( ${SEEN_COUNT[$version]:-0} + 1 ))
  done < <(releases_in "$packages")
done

# A release lands one architecture at a time and a single pkgver covers both,
# so only versions present in every architecture are candidates.
candidates=()
for version in "${!SEEN_COUNT[@]}"; do
  (( SEEN_COUNT[$version] == ${#DEB_ARCHES[@]} )) && candidates+=("$version")
done
(( ${#candidates[@]} )) || fail "No release found for every architecture in the signed index"

# Newest first, by pacman's comparator -- the one that decides whether a
# published package is an upgrade. sort -V disagrees with it at the corners.
newest_first=()
while (( ${#candidates[@]} )); do
  best_index=0
  for i in "${!candidates[@]}"; do
    if [[ $(vercmp "${candidates[$i]}" "${candidates[$best_index]}") -gt 0 ]]; then
      best_index=$i
    fi
  done
  newest_first+=("${candidates[$best_index]}")
  unset 'candidates[best_index]'
  candidates=("${candidates[@]}")
done

# The pool serves a Last-Modified for each .deb, which is when that build was
# actually published. A release counts as published when its last architecture
# lands, so the newer of the two timestamps is the conservative one to age
# against.
published_at_of() {
  local version="$1" newest_epoch=0 arch deb_arch header lm epoch

  for arch in "${!DEB_ARCHES[@]}"; do
    deb_arch="${DEB_ARCHES[$arch]}"
    header=$(curl -fsSLI \
      "$BASE_URL/pool/main/c/claude-desktop/claude-desktop_${version}_${deb_arch}.deb" 2>/dev/null) || return 1
    lm=$(awk -F': ' 'tolower($1) == "last-modified" { sub(/\r$/, "", $2); print $2; exit }' <<<"$header")
    [[ -n "$lm" ]] || return 1
    epoch=$(date --date="$lm" +%s 2>/dev/null) || return 1
    (( epoch > newest_epoch )) && newest_epoch=$epoch
  done

  (( newest_epoch > 0 )) || return 1
  date -u --date="@$newest_epoch" +%Y-%m-%dT%H:%M:%SZ
}

# Walk newest to oldest and report the first release that has cleared the
# quarantine window, so a bad release held back does not also hold back the
# good one before it.
now=$(date +%s)
for version in "${newest_first[@]}"; do
  published_at=$(published_at_of "$version") ||
    fail "Could not establish a publication time for $version"

  if (( MIN_AGE > 0 )) && [[ "$BYPASS" != "1" ]]; then
    published_epoch=$(date --date="$published_at" +%s)
    if (( now - published_epoch < MIN_AGE )); then
      continue
    fi
  fi

  jq -n \
    --arg pkgver "$version" \
    --arg published_at "$published_at" \
    --arg x86_64 "${CHECKSUMS["x86_64 $version"]}" \
    --arg aarch64 "${CHECKSUMS["aarch64 $version"]}" \
    '{
       pkgver: $pkgver,
       published_at: $published_at,
       sha256sums: { x86_64: [$x86_64], aarch64: [$aarch64] }
     }'
  exit 0
done

# Everything on offer is still inside the quarantine window.
echo '{}'
