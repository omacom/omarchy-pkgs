# Declarative upstream providers for bin/sync-upstream.
#
# A package whose upstream ships tagged GitHub releases needs no upstream.sh
# hook: the whole feed is data, declared in .omarchy/package.json --
#
#   "upstream": {
#     "github": "jdx/mise",
#     "checksums": "SHASUMS256.txt",
#     "assets": {
#       "x86_64": "mise-{tag}-linux-x64.tar.xz",
#       "aarch64": "mise-{tag}-linux-arm64.tar.xz"
#     }
#   }
#
# "checksums" names the vendor's manifest asset. A vendor publishing none can
# set "digests": true instead, which reads the SHA-256 digest GitHub's release
# API reports for every asset, so the sync never downloads the artifacts.
#
# {tag} and {pkgver} interpolate into asset names; tags may carry a leading
# "v", which is stripped for pkgver. Drafts and prereleases are ignored. The
# provider emits the same JSON contract as an upstream.sh hook, so
# bin/sync-upstream's validation and min_release_age backstop apply
# unchanged. Git-tag, npm, and Debian Packages providers below cover projects
# without GitHub releases; a feed that fits no convention keeps a bespoke hook.

# Return the single declarative provider selected by a package. An empty
# result means either no provider or an invalid/ambiguous declaration; the
# caller distinguishes those through package_has_upstream_provider().
package_upstream_provider() {
  local pkgdir="$1" metadata
  metadata=$(metadata_file_for_dir "$pkgdir")
  jq -r '
    (.upstream? | objects) as $u
    | [$u | keys[] | select(. == "github" or . == "git_tags" or . == "npm" or . == "debian")]
    | if length == 1 then .[0] else "" end
  ' "$metadata"
}

# Fetches sit behind functions so the self-test can replace them with fixture
# readers; everything below the fetch is deterministic and testable offline.
# Only the 100 most recent releases are considered -- a bounded search, not
# pagination. Quarantined releases report no update and wait for the next
# run; a page with no stable release at all (drafts and prereleases only)
# fails the sync instead, because a provider-tracked feed suddenly shipping
# nothing stable is an anomaly worth a loud error, not a silent skip.
github_fetch_releases() {
  local repo="$1"
  curl -fsSL "https://api.github.com/repos/$repo/releases?per_page=100"
}

github_fetch_checksums() {
  local repo="$1" tag="$2" asset="$3"
  curl -fsSL "https://github.com/$repo/releases/download/$tag/$asset"
}

git_tags_fetch_refs() {
  local repo="$1"
  git ls-remote --tags "$repo"
}

npm_fetch_metadata() {
  local package="$1" encoded
  encoded=$(jq -rn --arg package "$package" '$package | @uri')
  curl -fsSL "https://registry.npmjs.org/$encoded"
}

debian_fetch_packages() {
  local url="$1"
  curl --proto '=https' --proto-redir '=https' -fsSL "$url"
}

upstream_fetch_source() {
  local url="$1" output="$2"
  curl --proto '=https' --proto-redir '=https' -fsSL -o "$output" "$url"
}

# Hash every URL template in upstream.sources and emit hook-contract JSON.
# Templates may use {pkgver}, {tag}, and (for npm) {npm_tarball}. Downloads
# happen only after discovery reports a version newer than the PKGBUILD.
upstream_hash_sources() {
  local package_dir="$1" pkgver="$2" tag="${3:-}" npm_tarball="${4:-}"
  local metadata sources work result arch template url file sum sums index=0
  metadata=$(metadata_file_for_dir "$package_dir")
  sources=$(jq -c '.upstream.sources' "$metadata")
  work=$(mktemp -d)
  result=$(jq -n --arg pkgver "$pkgver" '{pkgver: $pkgver, sha256sums: {}}')

  while IFS= read -r arch; do
    sums='[]'
    while IFS= read -r template; do
      if [[ "$template" == file:* ]]; then
        file=${template#file:}
        if [[ ! "$file" =~ ^[A-Za-z0-9._+-]+$ || ! -f "$package_dir/$file" ]]; then
          echo "upstream source names an unsafe or missing local file: '$file'" >&2
          rm -rf "$work"
          return 1
        fi
        sum=$(sha256sum "$package_dir/$file" | cut -d' ' -f1)
        sums=$(jq -c --arg sum "$sum" '. + [$sum]' <<<"$sums")
        continue
      fi
      url=${template//\{pkgver\}/$pkgver}
      url=${url//\{tag\}/$tag}
      url=${url//\{npm_tarball\}/$npm_tarball}
      if [[ ! "$url" =~ ^https://[^[:space:]{}]+$ ]]; then
        echo "upstream source template produced an unsafe URL: '$url'" >&2
        rm -rf "$work"
        return 1
      fi
      file="$work/source-$((index += 1))"
      if ! upstream_fetch_source "$url" "$file"; then
        echo "could not fetch upstream source: $url" >&2
        rm -rf "$work"
        return 1
      fi
      sum=$(sha256sum "$file" | cut -d' ' -f1)
      sums=$(jq -c --arg sum "$sum" '. + [$sum]' <<<"$sums")
    done < <(jq -r --arg arch "$arch" '.[$arch][]' <<<"$sources")
    result=$(jq -c --arg arch "$arch" --argjson sums "$sums" '.sha256sums[$arch] = $sums' <<<"$result")
  done < <(jq -r 'keys[]' <<<"$sources")

  rm -rf "$work"
  printf '%s\n' "$result"
}

git_tags_upstream_release() {
  local package_dir="$1" metadata repo pattern prefix suffix refs
  metadata=$(metadata_file_for_dir "$package_dir")
  repo=$(jq -r '.upstream.git_tags // ""' "$metadata")
  pattern=$(jq -r '.upstream.tag_pattern // ""' "$metadata")
  prefix=${pattern%%\{pkgver\}*}
  suffix=${pattern#*\{pkgver\}}

  if [[ ! "$repo" =~ ^https://[^[:space:]]+\.git$ || "$pattern" != *'{pkgver}'* || "$suffix" == *'{pkgver}'* ]]; then
    echo "invalid git_tags provider configuration" >&2
    return 1
  fi
  if ! refs=$(git_tags_fetch_refs "$repo"); then
    echo "could not fetch tags from $repo" >&2
    return 1
  fi

  local best_pkgver="" best_tag="" tag candidate
  declare -A version_tags=()
  while read -r tag; do
    tag=${tag%\^\{\}}
    [[ "$tag" == "$prefix"*"$suffix" ]] || continue
    candidate=${tag#"$prefix"}
    [[ -z "$suffix" ]] || candidate=${candidate%"$suffix"}
    [[ "$candidate" =~ ^[A-Za-z0-9][A-Za-z0-9._+]*$ ]] || continue
    if [[ -n "${version_tags[$candidate]:-}" && "${version_tags[$candidate]}" != "$tag" ]]; then
      echo "multiple tags map to pkgver $candidate: ${version_tags[$candidate]} and $tag" >&2
      return 1
    fi
    version_tags[$candidate]="$tag"
    if [[ -z "$best_pkgver" || $(vercmp "$candidate" "$best_pkgver") -gt 0 ]]; then
      best_pkgver="$candidate"
      best_tag="$tag"
    fi
  done < <(sed -n 's#^.*refs/tags/##p' <<<"$refs")

  [[ -n "$best_pkgver" ]] || { echo "no usable tags found at $repo" >&2; return 1; }
  local current_pkgver
  current_pkgver=$(grep -m1 '^pkgver=' "$package_dir/PKGBUILD" | cut -d= -f2- | tr -d "\"'")
  if [[ $(vercmp "$best_pkgver" "$current_pkgver") -le 0 ]]; then
    echo '{}'
    return 0
  fi
  upstream_hash_sources "$package_dir" "$best_pkgver" "$best_tag"
}

npm_upstream_release() {
  local package_dir="$1" metadata package dist_tag npm_metadata pkgver tarball published_at release
  metadata=$(metadata_file_for_dir "$package_dir")
  package=$(jq -r '.upstream.npm // ""' "$metadata")
  dist_tag=$(jq -r '.upstream.dist_tag // "latest"' "$metadata")
  if [[ ! "$package" =~ ^(@[a-z0-9_.-]+/)?[a-z0-9_.-]+$ || ! "$dist_tag" =~ ^[a-z0-9_.-]+$ ]]; then
    echo "invalid npm provider configuration" >&2
    return 1
  fi
  if ! npm_metadata=$(npm_fetch_metadata "$package"); then
    echo "could not fetch npm metadata for $package" >&2
    return 1
  fi
  pkgver=$(jq -r --arg tag "$dist_tag" '."dist-tags"[$tag] // ""' <<<"$npm_metadata")
  tarball=$(jq -r --arg version "$pkgver" '.versions[$version].dist.tarball // ""' <<<"$npm_metadata")
  published_at=$(jq -r --arg version "$pkgver" '.time[$version] // ""' <<<"$npm_metadata")
  if [[ ! "$pkgver" =~ ^[A-Za-z0-9][A-Za-z0-9._+]*$ || ! "$tarball" =~ ^https://registry\.npmjs\.org/ ]]; then
    echo "npm returned an unusable $package release" >&2
    return 1
  fi

  local current_pkgver
  current_pkgver=$(grep -m1 '^pkgver=' "$package_dir/PKGBUILD" | cut -d= -f2- | tr -d "\"'")
  if [[ $(vercmp "$pkgver" "$current_pkgver") -le 0 ]]; then
    echo '{}'
    return 0
  fi
  release=$(upstream_hash_sources "$package_dir" "$pkgver" "$pkgver" "$tarball") || return 1
  if [[ -n "$published_at" ]]; then
    release=$(jq -c --arg published_at "$published_at" '.published_at = $published_at' <<<"$release")
  fi
  printf '%s\n' "$release"
}

# Discover a package version from a plain-text Debian Packages index, then
# hash the declared immutable sources. This intentionally supports only
# versions that are already valid Arch pkgver values; feeds needing Debian
# epoch/revision translation keep a package-specific hook.
debian_upstream_release() {
  local package_dir="$1" metadata index_url package packages
  metadata=$(metadata_file_for_dir "$package_dir")
  index_url=$(jq -r '.upstream.debian // ""' "$metadata")
  package=$(jq -r '.upstream.package // ""' "$metadata")

  if [[ ! "$index_url" =~ ^https://[^[:space:]]+$ || ! "$package" =~ ^[a-z0-9][a-z0-9+.-]*$ ]]; then
    echo "invalid Debian Packages provider configuration" >&2
    return 1
  fi
  if ! jq -e '
    .upstream.sources | type == "object" and length > 0 and (to_entries | all(
      (.key | test("\\A[a-z0-9_]+\\z"))
      and (.value | type == "array" and length > 0 and all(type == "string" and length > 0))
    ))
  ' "$metadata" >/dev/null; then
    echo "invalid Debian Packages source mapping" >&2
    return 1
  fi
  if ! packages=$(debian_fetch_packages "$index_url"); then
    echo "could not fetch Debian Packages index: $index_url" >&2
    return 1
  fi
  packages=${packages//$'\r'/}

  local best_pkgver="" candidate
  while IFS= read -r candidate; do
    if [[ ! "$candidate" =~ ^[A-Za-z0-9][A-Za-z0-9._+]*$ ]]; then
      echo "$package has an unusable Debian version: ${candidate:-<empty>}" >&2
      return 1
    fi
    if [[ -z "$best_pkgver" || $(vercmp "$candidate" "$best_pkgver") -gt 0 ]]; then
      best_pkgver="$candidate"
    fi
  done < <(awk -v target="$package" '
    BEGIN { RS = ""; FS = "\n" }
    {
      name = version = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^Package: /) name = substr($i, 10)
        if ($i ~ /^Version: /) version = substr($i, 10)
      }
      if (name == target) print version
    }
  ' <<<"$packages")

  [[ -n "$best_pkgver" ]] || {
    echo "no usable $package release found in $index_url" >&2
    return 1
  }

  local current_pkgver
  current_pkgver=$(grep -m1 '^pkgver=' "$package_dir/PKGBUILD" | cut -d= -f2- | tr -d "\"'")
  if [[ $(vercmp "$best_pkgver" "$current_pkgver") -le 0 ]]; then
    echo '{}'
    return 0
  fi

  upstream_hash_sources "$package_dir" "$best_pkgver" "$best_pkgver"
}

# Emits the newest qualifying release as hook-contract JSON. min_release_age
# is honored during selection (newest release older than the window wins,
# even when a younger one exists) and BYPASS_MIN_RELEASE_AGE=1 lifts it.
# Unusable tags or timestamps anywhere in the feed fail the sync rather than
# being skipped: a feed this provider cannot fully read is a feed it should
# not silently choose from.
github_upstream_release() {
  local package_dir="$1" min_age="${2:-0}"
  local metadata repo checksums_name use_digests latest_only
  metadata=$(metadata_file_for_dir "$package_dir")

  repo=$(jq -r '(.upstream? | objects | .github) // ""' "$metadata")
  if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "invalid upstream.github repository: '${repo:-<empty>}'" >&2
    return 1
  fi
  # Enforced here as well as in validate_package_metadata: the scheduled sync
  # reaches this provider without running the validator first.
  checksums_name=$(jq -r '(.upstream? | objects | .checksums) | strings' "$metadata")
  use_digests=$(jq -r '(.upstream? | objects | .digests) | if . == null then "false" elif type == "boolean" then tostring else "invalid" end' "$metadata")
  latest_only=$(jq -r '(.upstream? | objects | .latest_only) | if . == null then "false" elif type == "boolean" then tostring else "invalid" end' "$metadata")
  if [[ "$use_digests" == "invalid" ]]; then
    echo "upstream.digests must be true or false" >&2
    return 1
  fi
  if [[ "$latest_only" == "invalid" ]]; then
    echo "upstream.latest_only must be true or false" >&2
    return 1
  fi
  if [[ -n "$checksums_name" && "$use_digests" == "true" ]]; then
    echo "upstream sets both checksums and digests; keep exactly one" >&2
    return 1
  fi
  if [[ -z "$checksums_name" && "$use_digests" != "true" ]]; then
    echo "upstream needs either checksums (a manifest asset name) or digests: true" >&2
    return 1
  fi
  if ! jq -e '
    def valid_sources:
      type == "object" and length > 0 and (to_entries | all(
        (.key | test("\\A[a-z0-9_]+\\z"))
        and (.value | type == "array" and length > 0 and all(type == "string" and length > 0))
      ));
    (.upstream.assets | type == "object" and length > 0 and (to_entries | all(
      (.key | test("\\A[a-z0-9_]+\\z"))
      and (.value |
        (type == "string" and length > 0)
        or (type == "array" and length > 0 and all(type == "string" and length > 0) and (unique | length) == length)
      )
    )))
    and (if .upstream | has("sources") then
      (.upstream.sources | valid_sources)
      and ((.upstream.assets | keys) as $assets | (.upstream.sources | keys) as $sources | ($assets - $sources | length) == ($assets | length))
    else true end)
  ' "$metadata" >/dev/null; then
    echo "invalid upstream.assets or upstream.sources mapping" >&2
    return 1
  fi
  local arches
  mapfile -t arches < <(jq -r '(.upstream? | objects | .assets) // {} | keys[]' "$metadata")
  if [[ ${#arches[@]} -eq 0 ]]; then
    echo "upstream.assets must map at least one architecture to an asset name" >&2
    return 1
  fi

  local releases now
  now=$(date +%s)
  if ! releases=$(github_fetch_releases "$repo"); then
    echo "could not fetch the release feed for $repo" >&2
    return 1
  fi
  if [[ "$latest_only" == "true" ]]; then
    releases=$(jq '[.[] | select((.draft or .prerelease) | not)][0:1]' <<<"$releases")
  fi

  local candidates=0 best_tag="" best_pkgver="" best_published_at=""
  local tag published_at pkgver published_epoch
  while IFS=$'\t' read -r tag published_at; do
    if [[ ! "$tag" =~ ^v?([A-Za-z0-9._+]+)$ ]]; then
      echo "$repo release has an unusable tag: ${tag:-<empty>}" >&2
      return 1
    fi
    pkgver=${BASH_REMATCH[1]}

    if [[ -z "$published_at" ]] || ! published_epoch=$(date --date="$published_at" +%s 2>/dev/null); then
      echo "$repo release $tag has an invalid published_at: ${published_at:-<empty>}" >&2
      return 1
    fi
    candidates=$((candidates + 1))

    if (( now - published_epoch < min_age )); then
      if [[ "${BYPASS_MIN_RELEASE_AGE:-}" == "1" ]]; then
        echo "Bypassing release-age gate for $repo $tag" >&2
      else
        continue
      fi
    fi

    if [[ -z "$best_pkgver" ]] || [[ "$(vercmp "$pkgver" "$best_pkgver")" -gt 0 ]]; then
      best_tag=$tag
      best_pkgver=$pkgver
      best_published_at=$published_at
    fi
  # `// ""` rather than `// empty`: empty would drop the field and shift the
  # columns, so a malformed row could masquerade as a different one instead
  # of tripping the per-field checks above.
  done < <(jq -r '.[] | select((.draft or .prerelease) | not) | [.tag_name // "", .published_at // ""] | @tsv' <<<"$releases")

  if (( candidates == 0 )); then
    echo "no stable releases found in the feed for $repo" >&2
    return 1
  fi
  if [[ -z "$best_tag" ]]; then
    echo "every recent $repo release is still inside the release-age quarantine; skipping" >&2
    echo '{}'
    return 0
  fi

  # Already checked in: report no update instead of re-fetching checksums.
  local current_pkgver
  current_pkgver=$(grep -m1 '^pkgver=' "$package_dir/PKGBUILD" | cut -d= -f2- | tr -d "\"'")
  if [[ "$best_pkgver" == "$current_pkgver" ]]; then
    echo '{}'
    return 0
  fi

  local checksums=""
  if [[ "$use_digests" != "true" ]] \
      && ! checksums=$(github_fetch_checksums "$repo" "$best_tag" "$checksums_name"); then
    echo "could not fetch $checksums_name for $repo $best_tag" >&2
    return 1
  fi

  local result
  result=$(jq -n --arg pkgver "$best_pkgver" --arg published_at "$best_published_at" \
    '{pkgver: $pkgver, published_at: $published_at, sha256sums: {}}')
  local arch template filename checksum checksum_source sums
  for arch in "${arches[@]}"; do
    if [[ ! "$arch" =~ ^[a-z0-9_]+$ ]]; then
      echo "invalid architecture key in upstream.assets: '$arch'" >&2
      return 1
    fi
    sums='[]'
    while IFS= read -r template; do
      filename=${template//\{pkgver\}/$best_pkgver}
      filename=${filename//\{tag\}/$best_tag}
      if [[ "$use_digests" == "true" ]]; then
        # Only a "sha256:<hex>" digest is stripped to its hex; any other shape
        # falls through empty and fails the check below.
        checksum=$(jq -r --arg tag "$best_tag" --arg name "$filename" '
          first(.[] | select(.tag_name == $tag)) | (.assets // [])[]
          | select(.name == $name) | (.digest // "")
          | if type == "string" and test("\\Asha256:[0-9a-f]{64}\\z") then ltrimstr("sha256:") else "" end
        ' <<<"$releases")
        checksum_source="the release API digest"
      else
        # Manifest lines are "<sha256>  <name>", with the name sometimes prefixed
        # "./" (sha256sum of a local path) or "*" (binary-mode marker).
        checksum=$(awk -v f="$filename" '$2 == f || $2 == "./" f || $2 == "*" f { print $1; exit }' <<<"$checksums")
        checksum_source="$checksums_name"
      fi
      if [[ ! "$checksum" =~ ^[0-9a-f]{64}$ ]]; then
        echo "no valid checksum for $filename in $repo $best_tag $checksum_source" >&2
        return 1
      fi
      sums=$(jq -c --arg checksum "$checksum" '. + [$checksum]' <<<"$sums")
    done < <(jq -r --arg arch "$arch" '
      .upstream.assets[$arch] | if type == "array" then .[] else . end
    ' "$metadata")
    result=$(jq -c --arg arch "$arch" --argjson sums "$sums" '.sha256sums[$arch] = $sums' <<<"$result")
  done

  if jq -e '.upstream | has("sources")' "$metadata" >/dev/null; then
    local source_release
    source_release=$(upstream_hash_sources "$package_dir" "$best_pkgver" "$best_tag") || return 1
    result=$(jq -c --argjson source "$source_release" '.sha256sums += $source.sha256sums' <<<"$result")
  fi

  printf '%s\n' "$result"
}
