#!/bin/bash
# Flea publishes signed source tags but no release artifacts or checksum manifest.
# Check the small GitHub source tarball only when a newer stable release exists,
# validate its expected root, then report its hash alongside the fixed hashes of
# the four upstream security patches carried until a release includes them.
set -euo pipefail

REPO='thisisgm/flea'
RELEASES_URL="https://api.github.com/repos/$REPO/releases?per_page=100"
PATCH_2BD7CC2='c610a9f44294b67341940203943c9c567003b65cc436d6013cd36754379183d8'
PATCH_27D19CA='e457ef17e26f70057b1184eeb938fccc5906f48a7c77f1df573d55d13a845425'
PATCH_23290CE='f8381456a3b5f39d341cc6610bf27beb8354892b17a1c8c6d7882db4e40824c3'
PATCH_B4B7EE4='46bdbe43f135a052c893b1987f8b0928736445616a84b0c65d2181ee74b21b25'

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
curl -fsSL -o "$tarball" "https://github.com/$REPO/archive/refs/tags/$best_tag.tar.gz"

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

if ! grep -Fq 'a.push("--".to_string());' <<<"$archive_rs" ||
  ! grep -Fq 'let input = std::fs::canonicalize(input)' <<<"$archiveops_rs" ||
  ! grep -Fq 'if op != "compress" && op != "extract"' <<<"$run_rs$archivereq_rs" ||
  ! grep -Fq 'the sandbox is unavailable: bwrap or prlimit is not on PATH' <<<"$archivework_rs" ||
  ! grep -Fq 'if !sandbox::available()' <<<"$mediaprobe_rs" ||
  ! grep -Fq 'if !sandbox::available()' <<<"$metareq_rs" ||
  ! grep -Fq 'copyToClipboard.command = ["wl-copy", url]' <<<"$sharelink_qml" ||
  ! grep -Fq '.custom_flags(O_NOFOLLOW)' <<<"$copyfile_rs"; then
  printf 'Release %s does not contain every required upstream security fix\n' "$best_tag" >&2
  exit 1
fi

jq -n \
  --arg pkgver "$best_version" \
  --arg published_at "$best_published_at" \
  --arg source "$(sha256sum "$tarball" | cut -d' ' -f1)" \
  --arg patch_2bd7cc2 "$PATCH_2BD7CC2" \
  --arg patch_27d19ca "$PATCH_27D19CA" \
  --arg patch_23290ce "$PATCH_23290CE" \
  --arg patch_b4b7ee4 "$PATCH_B4B7EE4" \
  '{pkgver: $pkgver, published_at: $published_at, sha256sums: {any: [$source, $patch_2bd7cc2, $patch_27d19ca, $patch_23290ce, $patch_b4b7ee4]}}'
