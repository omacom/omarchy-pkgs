#!/bin/bash
# Verify Flea's published source archive against its checksum manifest when a
# newer stable release exists, then check its root and required security fixes.
set -euo pipefail

REPO='thisisgm/flea'
RELEASES_URL="https://api.github.com/repos/$REPO/releases?per_page=100"

current=$(awk -F= '/^pkgver=/ { print $2; exit }' PKGBUILD)
releases=$(curl -fsSL "$RELEASES_URL")
now=$(date +%s)
min_age=${MIN_RELEASE_AGE_SECONDS:-0}

candidates=0
best_version=''
best_tag=''
best_published_at=''

while IFS=$'\t' read -r tag published_at; do
  if [[ ! $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    printf '%s has an unusable stable release tag: %s\n' "$REPO" "${tag:-<empty>}" >&2
    exit 1
  fi
  version=${BASH_REMATCH[1]}

  if [[ -z $published_at ]] || ! published_epoch=$(date --date="$published_at" +%s 2>/dev/null); then
    printf '%s release %s has an invalid publication time\n' "$REPO" "$tag" >&2
    exit 1
  fi
  candidates=$((candidates + 1))

  if (( now - published_epoch < min_age )) && [[ ${BYPASS_MIN_RELEASE_AGE:-} != 1 ]]; then
    continue
  fi

  if [[ -z $best_version ]] || (( $(vercmp "$version" "$best_version") > 0 )); then
    best_version=$version
    best_tag=$tag
    best_published_at=$published_at
  fi
done < <(jq -r '.[] | select((.draft or .prerelease) | not) | [.tag_name // "", .published_at // ""] | @tsv' <<<"$releases")

if (( candidates == 0 )); then
  printf 'No stable releases found for %s\n' "$REPO" >&2
  exit 1
fi

if [[ -z $best_version ]] || (( $(vercmp "$best_version" "$current") <= 0 )); then
  echo '{}'
  exit 0
fi

tarball=$(mktemp)
trap 'rm -f "$tarball"' EXIT
release_url="https://github.com/$REPO/releases/download/$best_tag"
asset="flea-$best_tag.tar.gz"
checksums=$(curl -fsSL "$release_url/SHASUMS256.txt")
expected_sum=$(awk -v asset="$asset" '$2 == asset { print $1 }' <<<"$checksums")
if [[ ! $expected_sum =~ ^[0-9a-f]{64}$ ]]; then
  printf 'Release %s has no unique SHA-256 checksum for %s\n' "$best_tag" "$asset" >&2
  exit 1
fi
curl -fsSL -o "$tarball" "$release_url/$asset"
source_sum=$(sha256sum "$tarball" | cut -d' ' -f1)
if [[ $source_sum != "$expected_sum" ]]; then
  printf 'Release %s source archive does not match its checksum manifest\n' "$best_tag" >&2
  exit 1
fi

expected_root="flea-$best_version"
served_roots=$(tar -tzf "$tarball" | cut -d/ -f1 | sort -u)
if [[ $served_roots != "$expected_root" ]]; then
  printf 'Release %s contains root %s, expected %s\n' "$best_tag" "$served_roots" "$expected_root" >&2
  exit 1
fi

archive_rs=$(tar -xOzf "$tarball" "$expected_root/src/backend/archive.rs")
archiveops_rs=$(tar -xOzf "$tarball" "$expected_root/src/backend/archiveops.rs")
run_rs=$(tar -xOzf "$tarball" "$expected_root/src/backend/run.rs")
archivereq_rs=$(tar -xOzf "$tarball" "$expected_root/src/backend/archivereq.rs")
archivework_rs=$(tar -xOzf "$tarball" "$expected_root/src/backend/archivework.rs")
mediaprobe_rs=$(tar -xOzf "$tarball" "$expected_root/src/backend/mediaprobe.rs")
metareq_rs=$(tar -xOzf "$tarball" "$expected_root/src/backend/metareq.rs")
sharelink_qml=$(tar -xOzf "$tarball" "$expected_root/ui/ShareLink.qml")
copyfile_rs=$(tar -xOzf "$tarball" "$expected_root/src/backend/copyfile.rs")
regfile_rs=$(tar -xOzf "$tarball" "$expected_root/src/backend/regfile.rs")

# Every check below pins a literal line except the O_NOFOLLOW one. That check
# guards a property -- the copy opens its source with O_NOFOLLOW, so a symlink
# swapped in cannot redirect the read -- and pinning the exact call expression
# made it assert the spelling instead. v0.3.0 moved the first argument from
# `src` to `src.at` when directory-relative opens landed, kept O_NOFOLLOW, and
# hardened symlink handling further; the literal still refused it. Match the
# call and the flag together so a rename cannot read as a removed fix, while
# dropping O_NOFOLLOW still fails.
if ! grep -Fq 'a.push("--".to_string());' <<<"$archive_rs" ||
  ! grep -Fq 'let input = std::fs::canonicalize(input)' <<<"$archiveops_rs" ||
  ! grep -Fq 'if op != "compress" && op != "extract"' <<<"$run_rs$archivereq_rs" ||
  ! grep -Fq 'the sandbox is unavailable: bwrap or prlimit is not on PATH' <<<"$archivework_rs" ||
  ! grep -Fq 'if !sandbox::available()' <<<"$mediaprobe_rs" ||
  ! grep -Fq 'if !sandbox::available()' <<<"$metareq_rs" ||
  ! grep -Fq 'copyToClipboard.command = ["wl-copy", url]' <<<"$sharelink_qml" ||
  ! grep -Eq 'open_if_regular\(.*O_NOFOLLOW' <<<"$copyfile_rs" ||
  ! grep -Fq '.custom_flags(O_NONBLOCK | extra_flags)' <<<"$regfile_rs"; then
  printf 'Release %s does not contain every required upstream security fix\n' "$best_tag" >&2
  exit 1
fi

jq -n \
  --arg pkgver "$best_version" \
  --arg published_at "$best_published_at" \
  --arg source "$source_sum" \
  '{pkgver: $pkgver, published_at: $published_at, sha256sums: {any: [$source]}}'
