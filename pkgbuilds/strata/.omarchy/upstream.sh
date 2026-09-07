#!/bin/bash
# Strata publishes annotated tags and GitHub source archives, but no checksum
# manifest. Download the small archive only when a newer stable release exists,
# then verify that its embedded commit matches the release tag before hashing it.
set -euo pipefail

REPO='lgse/strata'
API_URL="https://api.github.com/repos/$REPO"

current=$(awk -F= '/^pkgver=/ { print $2; exit }' PKGBUILD)
releases=$(curl -fsSL "$API_URL/releases?per_page=100")
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

  if ((now - published_epoch < min_age)) && [[ ${BYPASS_MIN_RELEASE_AGE:-} != 1 ]]; then
    continue
  fi

  if [[ -z $best_version ]] || (( $(vercmp "$version" "$best_version") > 0 )); then
    best_version=$version
    best_tag=$tag
    best_published_at=$published_at
  fi
done < <(jq -r '.[] | select((.draft or .prerelease) | not) | [.tag_name // "", .published_at // ""] | @tsv' <<<"$releases")

if ((candidates == 0)); then
  printf 'No stable releases found for %s\n' "$REPO" >&2
  exit 1
fi

if [[ -z $best_version ]] || (( $(vercmp "$best_version" "$current") <= 0 )); then
  echo '{}'
  exit 0
fi

tag_ref=$(curl -fsSL "$API_URL/git/ref/tags/$best_tag")
tag_type=$(jq -r '.object.type // empty' <<<"$tag_ref")
tag_object=$(jq -r '.object.sha // empty' <<<"$tag_ref")
if [[ ! $tag_object =~ ^[0-9a-f]{40}$ ]]; then
  printf 'Release %s has an invalid tag object\n' "$best_tag" >&2
  exit 1
fi

case "$tag_type" in
  commit)
    expected_commit=$tag_object
    ;;
  tag)
    tag_data=$(curl -fsSL "$API_URL/git/tags/$tag_object")
    if [[ $(jq -r '.object.type // empty' <<<"$tag_data") != commit ]]; then
      printf 'Release %s does not resolve to a commit\n' "$best_tag" >&2
      exit 1
    fi
    expected_commit=$(jq -r '.object.sha // empty' <<<"$tag_data")
    ;;
  *)
    printf 'Release %s has unsupported tag object type %s\n' "$best_tag" "${tag_type:-<empty>}" >&2
    exit 1
    ;;
esac

if [[ ! $expected_commit =~ ^[0-9a-f]{40}$ ]]; then
  printf 'Release %s resolves to an invalid commit\n' "$best_tag" >&2
  exit 1
fi

tarball=$(mktemp)
trap 'rm -f "$tarball"' EXIT
curl -fsSL -o "$tarball" "https://github.com/$REPO/archive/refs/tags/$best_tag.tar.gz"

expected_root="strata-$best_version"
served_roots=$(tar -tzf "$tarball" | cut -d/ -f1 | sort -u)
if [[ $served_roots != "$expected_root" ]]; then
  printf 'Release %s contains root %s, expected %s\n' "$best_tag" "$served_roots" "$expected_root" >&2
  exit 1
fi

if ! archive_commit=$(git get-tar-commit-id < <(gzip -dc "$tarball")) ||
  [[ $archive_commit != "$expected_commit" ]]; then
  printf 'Release %s archive commit does not match its tag\n' "$best_tag" >&2
  exit 1
fi

jq -n \
  --arg pkgver "$best_version" \
  --arg published_at "$best_published_at" \
  --arg source "$(sha256sum "$tarball" | cut -d' ' -f1)" \
  '{pkgver: $pkgver, published_at: $published_at, sha256sums: {any: [$source]}}'
