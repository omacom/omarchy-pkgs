# Package metadata helpers for Omarchy package build tooling
#
# Expects package directories in $PKGBUILDS_DIR, each with:
#   .omarchy/package.json
#
# Minimal schema:
#   { "source": "aur" }
#   { "source": "aur", "sync": false }
#   { "source": "aur", "aur": "different-aur-name" }
#   { "source": "aur", "release_ring": "fast" }
#   { "source": "aur", "skip_build": true }
#   { "source": "aur", "pkgrel": { "suffix": 1, "offset": 1 } }
#   { "source": "aur", "rebuild_on": ["qt6-base"] }
#   { "source": "local" }
#   { "source": "local", "channels": ["edge"] }
#   { "source": "local", "channels": ["edge", "rc", "stable"] }
#   { "source": "local", "min_release_age": "24h" }
#   { "source": "local", "upstream": { "github": "owner/repo", "checksums": "SHASUMS256.txt", "assets": { "x86_64": ["name-{tag}-x64.tar.xz"] } } }
#   { "source": "local", "upstream": { "github": "owner/repo", "digests": true, "assets": { "x86_64": "name-{tag}-x64.tar.xz" } } }
#   { "source": "local", "upstream": { "git_tags": "https://example/repo.git", "tag_pattern": "v{pkgver}", "sources": { "any": ["https://example/archive/{tag}.tar.gz"] } } }
#   { "source": "local", "upstream": { "npm": "@scope/package", "sources": { "any": ["{npm_tarball}"] } } }
#   { "source": "local", "upstream": { "debian": "https://example/debian/dists/stable/main/binary-amd64/Packages", "package": "example", "sources": { "any": ["https://example/releases/{pkgver}.tar.gz"] } } }
#
# bin/sync-aur also writes upstream_commit for AUR-backed packages, and
# bin/sync-rebuilds writes rebuilt_against for packages declaring rebuild_on.

if [[ -z "${PKGBUILDS_DIR:-}" ]]; then
  if [[ -n "${BUILD_ROOT:-}" ]]; then
    PKGBUILDS_DIR="$BUILD_ROOT/pkgbuilds"
  elif [[ -d /pkgbuilds ]]; then
    PKGBUILDS_DIR="/pkgbuilds"
  else
    PKGBUILDS_DIR="pkgbuilds"
  fi
fi

metadata_file_for_dir() {
  local pkgdir="$1"
  echo "$pkgdir/.omarchy/package.json"
}

package_dir_for_name() {
  local package="$1"
  local pkgdir="$PKGBUILDS_DIR/$package"

  [[ -d "$pkgdir" && -f "$pkgdir/PKGBUILD" ]] || return 1
  echo "$pkgdir"
}

package_metadata_value() {
  local pkgdir="$1"
  local jq_filter="$2"
  local default="${3:-}"
  local metadata

  metadata=$(metadata_file_for_dir "$pkgdir")
  if [[ ! -f "$metadata" ]]; then
    echo "$default"
    return 0
  fi

  jq -r --arg default "$default" "$jq_filter // \$default" "$metadata"
}

package_sync_enabled() {
  local pkgdir="$1"
  local metadata source sync

  metadata=$(metadata_file_for_dir "$pkgdir")
  [[ -f "$metadata" ]] || return 1

  source=$(jq -r '.source // ""' "$metadata")
  [[ "$source" == "aur" ]] || return 1

  sync=$(jq -r 'if has("sync") then .sync else true end' "$metadata")
  [[ "$sync" != "false" ]]
}

package_release_ring() {
  local pkgdir="$1"
  package_metadata_value "$pkgdir" '.release_ring' ""
}

package_is_fast_ring() {
  local pkgdir="$1"
  [[ "$(package_release_ring "$pkgdir")" == "fast" ]]
}

# Quarantine window for upstream releases, in seconds. Accepts a bare number
# of seconds or a number suffixed s/m/h/d ("24h", "2d"). Unset means 0 (no
# hold); an unparseable value -- including a non-string/non-number JSON type
# like false -- returns 1 so callers fail closed instead of silently dropping
# the hold. At most 9 digits: enough for three decades in seconds, and small
# enough that no suffix multiplication can overflow 64-bit arithmetic.
package_min_release_age_seconds() {
  local pkgdir="$1" metadata raw
  metadata=$(metadata_file_for_dir "$pkgdir")
  if [[ ! -f "$metadata" ]]; then
    echo 0
    return 0
  fi
  # A present-but-empty value maps to "unparseable", not to "absent": only a
  # missing key means no hold, so '"min_release_age": ""' cannot silently
  # disable the quarantine.
  raw=$(jq -r '
    if has("min_release_age") | not then ""
    elif (.min_release_age | type) == "string" or (.min_release_age | type) == "number" then
      .min_release_age | tostring | if . == "" then "unparseable" else . end
    else "unparseable" end
  ' "$metadata")
  if [[ -z "$raw" ]]; then
    echo 0
    return 0
  fi
  [[ "$raw" =~ ^([0-9]{1,9})([smhd]?)$ ]] || return 1
  # Forced base 10: bash arithmetic would otherwise read "010" as octal.
  local n=$((10#${BASH_REMATCH[1]}))
  case "${BASH_REMATCH[2]}" in
    ""|s) echo "$n" ;;
    m) echo $((n * 60)) ;;
    h) echo $((n * 3600)) ;;
    d) echo $((n * 86400)) ;;
  esac
}

package_build_skipped() {
  local pkgdir="$1"
  local metadata skip_build

  metadata=$(metadata_file_for_dir "$pkgdir")
  [[ -f "$metadata" ]] || return 1

  skip_build=$(jq -r 'if has("skip_build") then .skip_build else false end' "$metadata")
  [[ "$skip_build" == "true" ]]
}

package_has_metadata() {
  local pkgdir="$1"
  [[ -f "$(metadata_file_for_dir "$pkgdir")" ]]
}

package_has_pkgbuild() {
  local pkgdir="$1"
  [[ -f "$pkgdir/PKGBUILD" ]]
}

# Read one variable from a PKGBUILD the way makepkg would see it.
#
# makepkg always exports CARCH, so PKGBUILDs may branch on it at file scope
# (per-architecture sources, tarball suffixes, even `return` for an
# unsupported architecture). Sourcing without CARCH takes the wrong branch or
# aborts partway, which leaves pkgver and pkgrel empty — and an empty version
# never equals the published one, so the package is queued for a rebuild that
# promotion then refuses. Every read of a PKGBUILD goes through here.
#
# Prints the value; exit status is that of `source PKGBUILD` itself, so a
# caller can tell "variable empty" from "PKGBUILD could not be read".
package_pkgbuild_var() {
  local pkgdir="$1"
  local var="$2"
  local arch="${3:-${ARCH:-x86_64}}"

  (cd "$pkgdir" && env -u OMARCHY_SRC CARCH="$arch" bash -c '
    source PKGBUILD >/dev/null 2>&1
    rc=$?
    printf "%s\n" "${!1:-}"
    exit "$rc"
  ' _ "$var")
}

# The architectures declared by a PKGBUILD. Set CARCH while reading it so a
# conditional arch=() assignment is evaluated for the architecture we are
# actually checking, even when the repository host is a different one.
package_arches() {
  local pkgdir="$1"
  local arch="${2:-${ARCH:-x86_64}}"

  (cd "$pkgdir" && env -u OMARCHY_SRC CARCH="$arch" bash -c '
    source PKGBUILD >/dev/null 2>&1
    printf "%s\n" "${arch[*]}"
  ')
}

package_supports_arch() {
  local pkgdir="$1"
  local target="${2:-${ARCH:-x86_64}}"
  local arches

  arches=$(package_arches "$pkgdir" "$target") || return 1
  case " $arches " in
    *" any "* | *" $target "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Channel membership: where a package may be published. Packages without a
# `channels` key are members of every channel (they flow edge -> rc -> stable).
package_has_channels() {
  local pkgdir="$1" metadata
  metadata=$(metadata_file_for_dir "$pkgdir")
  [[ -f "$metadata" ]] || return 1
  jq -e 'has("channels")' "$metadata" >/dev/null
}

package_channels() {
  local pkgdir="$1" metadata
  metadata=$(metadata_file_for_dir "$pkgdir")
  [[ -f "$metadata" ]] || return 0
  jq -r '(.channels // [])[]' "$metadata"
}

package_in_channel() {
  local pkgdir="$1" channel="$2"
  package_has_channels "$pkgdir" || return 0
  package_channels "$pkgdir" | grep -qx "$channel"
}

# A pinned package's version is set per release by the orchestrator on the rc
# branch, not by whatever the current checkout happens to say. Only a build
# running from that branch's worktree (OMARCHY_RC_PINS=1) may build it for rc;
# otherwise master's shipped pins would try to overwrite an in-flight RC with
# an older version.
package_is_pinned() {
  local pkgdir="$1" metadata
  metadata=$(metadata_file_for_dir "$pkgdir")
  [[ -f "$metadata" ]] || return 1
  [[ "$(jq -r 'if has("pinned") then .pinned else false end' "$metadata")" == "true" ]]
}

package_builds_for_mirror() {
  local pkgdir="$1"
  local mirror="$2"

  package_has_pkgbuild "$pkgdir" || return 1
  package_has_metadata "$pkgdir" || return 1

  # An explicit `channels` key is the outer bound on where a package may be
  # built at all.
  if package_has_channels "$pkgdir" && ! package_in_channel "$pkgdir" "$mirror"; then
    return 1
  fi

  case "$mirror" in
    edge)
      return 0
      ;;
    rc)
      # Fast-ring packages build for rc natively rather than being copied from
      # stable: the rc channel's Arch base can be sitting anywhere between
      # stable's snapshot and edge's, so an artifact linked against stable's
      # libraries is not necessarily correct for rc.
      package_is_pinned "$pkgdir" && { [[ -n "${OMARCHY_RC_PINS:-}" ]]; return; }
      package_is_fast_ring "$pkgdir"
      ;;
    stable)
      package_is_pinned "$pkgdir" && return 1
      package_is_fast_ring "$pkgdir"
      ;;
    *)
      return 1
      ;;
  esac
}

# Whether `bin/repo advance` may carry this package into the given channel:
# a member of that channel that is not built there natively. Native builds are
# authoritative — advancing over them could pair a published filename with
# different bytes, which the R2 cache would never recover from.
package_moves_to_channel() {
  local pkgdir="$1" channel="$2"
  package_in_channel "$pkgdir" "$channel" || return 1
  ! package_builds_for_mirror "$pkgdir" "$channel"
}

package_dirs() {
  [[ -d "$PKGBUILDS_DIR" ]] || return 0

  find "$PKGBUILDS_DIR" -mindepth 1 -maxdepth 1 -type d -print | sort | while IFS= read -r pkgdir; do
    package_has_pkgbuild "$pkgdir" || continue
    package_has_metadata "$pkgdir" || continue
    echo "$pkgdir"
  done
}

packages_for_aur_sync() {
  package_dirs | while IFS= read -r pkgdir; do
    if package_sync_enabled "$pkgdir"; then
      basename "$pkgdir"
    fi
  done
}

package_has_upstream_hook() {
  local pkgdir="$1"
  [[ -f "$pkgdir/.omarchy/upstream.sh" ]]
}

package_has_upstream_provider() {
  local pkgdir="$1" metadata
  metadata=$(metadata_file_for_dir "$pkgdir")
  [[ -f "$metadata" ]] || return 1
  # Any upstream key counts, valid or not: a malformed declaration must reach
  # bin/sync-upstream and fail loudly there, not vanish from discovery.
  jq -e 'has("upstream")' "$metadata" >/dev/null
}

packages_for_upstream_sync() {
  package_dirs | while IFS= read -r pkgdir; do
    if package_has_upstream_hook "$pkgdir" || package_has_upstream_provider "$pkgdir"; then
      basename "$pkgdir"
    fi
  done
}

# Packages that must be rebuilt when a dependency they link against changes,
# even though nothing in their own source moved. `rebuild_on` names those
# dependencies; `rebuilt_against` records the versions the checked-in pkgrel was
# last bumped for.
package_rebuild_triggers() {
  local pkgdir="$1"
  local metadata

  metadata=$(metadata_file_for_dir "$pkgdir")
  [[ -f "$metadata" ]] || return 0

  jq -r '(.rebuild_on // [])[]' "$metadata"
}

package_has_rebuild_triggers() {
  local pkgdir="$1"
  [[ -n "$(package_rebuild_triggers "$pkgdir")" ]]
}

packages_for_rebuild_sync() {
  package_dirs | while IFS= read -r pkgdir; do
    if package_has_rebuild_triggers "$pkgdir"; then
      basename "$pkgdir"
    fi
  done
}

packages_for_mirror() {
  local mirror="$1"

  package_dirs | while IFS= read -r pkgdir; do
    if package_builds_for_mirror "$pkgdir" "$mirror"; then
      basename "$pkgdir"
    fi
  done
}

packages_for_unscoped_build() {
  local mirror="$1"
  local arch="${2:-${ARCH:-x86_64}}"

  package_dirs | while IFS= read -r pkgdir; do
    if package_builds_for_mirror "$pkgdir" "$mirror" &&
      ! package_build_skipped "$pkgdir" &&
      package_supports_arch "$pkgdir" "$arch"; then
      basename "$pkgdir"
    fi
  done
}

package_extract_vcs_hash_from_version() {
  local version="$1"
  local version_no_pkgrel="${version%-*}"
  local candidate hash=""

  # Drop an epoch prefix before scanning for commit-looking components.
  if [[ "$version_no_pkgrel" == *:* ]]; then
    version_no_pkgrel="${version_no_pkgrel#*:}"
  fi

  while IFS= read -r candidate; do
    # Prefer candidates explicitly prefixed with `g`, but also accept bare hex
    # hashes that contain at least one a-f character (e.g. r21251.626ee68).
    if [[ "$candidate" == g* || "$candidate" =~ [a-f] ]]; then
      hash="${candidate#g}"
    fi
  done < <(echo "$version_no_pkgrel" | grep -oE 'g?[a-f0-9]{7,40}')

  [[ -n "$hash" ]] && echo "${hash:0:7}"
}

package_first_git_source() {
  local pkgdir="$1"

  (cd "$pkgdir" && env -u OMARCHY_SRC bash -c '
    source PKGBUILD 2>/dev/null
    for s in "${source[@]}"; do
      url="${s#*::}"
      [[ "$url" == git+* ]] && { echo "${url#git+}"; break; }
    done')
}

package_git_upstream_hash() {
  local pkgdir="$1"
  local source_spec source_url fragment ref hash

  source_spec=$(package_first_git_source "$pkgdir") || return 1
  [[ -n "$source_spec" ]] || return 1

  source_url="${source_spec%%#*}"
  fragment=""
  if [[ "$source_spec" == *"#"* ]]; then
    fragment="${source_spec#*#}"
  fi

  case "$fragment" in
    "")
      hash=$(git ls-remote "$source_url" HEAD 2>/dev/null | awk 'NR == 1 { print substr($1, 1, 7) }')
      ;;
    branch=*)
      ref="${fragment#branch=}"
      [[ -n "$ref" ]] || return 1
      hash=$(git ls-remote "$source_url" "refs/heads/$ref" 2>/dev/null | awk 'NR == 1 { print substr($1, 1, 7) }')
      ;;
    tag=*)
      ref="${fragment#tag=}"
      [[ -n "$ref" ]] || return 1
      hash=$(git ls-remote "$source_url" "refs/tags/$ref^{}" "refs/tags/$ref" 2>/dev/null | awk '
        $2 ~ /\^\{\}$/ { print substr($1, 1, 7); found=1; exit }
        NR == 1 { first=substr($1, 1, 7) }
        END { if (!found && first != "") print first }
      ')
      ;;
    commit=*)
      ref="${fragment#commit=}"
      [[ "$ref" =~ ^[a-f0-9]{7,40}$ ]] || return 1
      hash="${ref:0:7}"
      ;;
    *)
      return 1
      ;;
  esac

  [[ -n "$hash" ]] || return 1
  echo "$hash"
}

validate_package_metadata() {
  local pkgdir="$1"
  local metadata source sync skip_build aur ring pkgrel_type

  metadata=$(metadata_file_for_dir "$pkgdir")
  [[ -f "$metadata" ]] || { echo "missing metadata: $metadata"; return 1; }

  jq empty "$metadata" >/dev/null || return 1

  source=$(jq -r '.source // ""' "$metadata")
  case "$source" in
    aur|local) ;;
    *) echo "invalid source for $(basename "$pkgdir"): $source"; return 1 ;;
  esac

  sync=$(jq -r 'if has("sync") then .sync | type else "missing" end' "$metadata")
  case "$sync" in
    boolean|missing) ;;
    *) echo "invalid sync for $(basename "$pkgdir"): must be boolean"; return 1 ;;
  esac

  skip_build=$(jq -r 'if has("skip_build") then .skip_build | type else "missing" end' "$metadata")
  case "$skip_build" in
    boolean|missing) ;;
    *) echo "invalid skip_build for $(basename "$pkgdir"): must be boolean"; return 1 ;;
  esac

  aur=$(jq -r 'if has("aur") then .aur | type else "missing" end' "$metadata")
  case "$aur" in
    string|missing) ;;
    *) echo "invalid aur for $(basename "$pkgdir"): must be string"; return 1 ;;
  esac

  ring=$(jq -r '.release_ring // ""' "$metadata")
  case "$ring" in
    ""|fast) ;;
    *) echo "invalid release_ring for $(basename "$pkgdir"): $ring"; return 1 ;;
  esac

  if ! jq -e 'if has("pinned") | not then true else (.pinned | type) == "boolean" end' "$metadata" >/dev/null; then
    echo "invalid pinned for $(basename "$pkgdir"): must be boolean"
    return 1
  fi

  if ! jq -e '
    if has("channels") | not then true
    else .channels | type == "array" and length > 0
      and all(. == "edge" or . == "rc" or . == "stable")
      and (unique | length) == length
    end
  ' "$metadata" >/dev/null; then
    echo "invalid channels for $(basename "$pkgdir"): must be a non-empty array of unique edge/rc/stable values"
    return 1
  fi

  if ! package_min_release_age_seconds "$pkgdir" >/dev/null; then
    echo "invalid min_release_age for $(basename "$pkgdir"): must be a number with optional s/m/h/d suffix"
    return 1
  fi

  # `has` rather than `// {}`: jq's // treats false as absent, which would
  # let "upstream": false slip through as an empty declaration.
  if ! jq -e '
    def valid_sources:
      type == "object" and length > 0 and (to_entries | all(
        (.key | test("\\A[a-z0-9_]+\\z"))
        and (.value | type == "array" and length > 0 and all(type == "string" and length > 0))
      ));
    def valid_assets:
      type == "object" and length > 0 and (to_entries | all(
        (.key | test("\\A[a-z0-9_]+\\z"))
        and (.value |
          (type == "string" and length > 0)
          or (type == "array" and length > 0 and all(type == "string" and length > 0) and (unique | length) == length)
        )
      ));
    if has("upstream") | not then true
    elif (.upstream | type) != "object" then false
    else .upstream |
      ([has("github"), has("git_tags"), has("npm"), has("debian")] | map(select(.)) | length) == 1
      and if has("github") then
        (.github | type == "string" and test("\\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\\z"))
        and (if has("checksums") then (.checksums | type == "string" and length > 0) else true end)
        and (if has("digests") then (.digests | type == "boolean") else true end)
        and (if has("latest_only") then (.latest_only | type == "boolean") else true end)
        and (has("checksums") != (has("digests") and .digests == true))
        and (.assets | valid_assets)
        and (if has("sources") then
          (.sources | valid_sources)
          and ((.assets | keys) as $assets | (.sources | keys) as $sources | ($assets - $sources | length) == ($assets | length))
        else true end)
      elif has("git_tags") then
        (.git_tags | type == "string" and test("\\Ahttps://[^[:space:]]+\\.git\\z"))
        and (.tag_pattern | type == "string" and (split("{pkgver}") | length) == 2)
        and (.sources | valid_sources)
      elif has("npm") then
        (.npm | type == "string" and test("\\A(@[a-z0-9_.-]+/)?[a-z0-9_.-]+\\z"))
        and ((.dist_tag // "latest") | type == "string" and test("\\A[a-z0-9_.-]+\\z"))
        and (.sources | valid_sources)
      else
        (.debian | type == "string" and test("\\Ahttps://[^[:space:]]+\\z"))
        and (.package | type == "string" and test("\\A[a-z0-9][a-z0-9+.-]*\\z"))
        and (.sources | valid_sources)
      end
    end
  ' "$metadata" >/dev/null; then
    echo "invalid upstream for $(basename "$pkgdir"): configure exactly one valid github, git_tags, npm, or debian provider"
    return 1
  fi

  pkgrel_type=$(jq -r 'if has("pkgrel") then .pkgrel | type else "missing" end' "$metadata")
  case "$pkgrel_type" in
    object|missing) ;;
    *) echo "invalid pkgrel for $(basename "$pkgdir"): must be an object with optional suffix/offset"; return 1 ;;
  esac

  if ! jq -e '(.pkgrel // {}) | type == "object" and ((.suffix // 1) | type == "number" and floor == . and . >= 1) and ((.offset // 0) | type == "number" and floor == . and . >= 0)' "$metadata" >/dev/null; then
    echo "invalid pkgrel for $(basename "$pkgdir"): must be an object with optional integer suffix >= 1 and offset >= 0"
    return 1
  fi

  if ! jq -e '(.upstream_commit // "") | type == "string"' "$metadata" >/dev/null; then
    echo "invalid upstream_commit for $(basename "$pkgdir"): must be a string"
    return 1
  fi

  if ! jq -e '(.rebuild_on // []) | type == "array" and all(type == "string" and length > 0)' "$metadata" >/dev/null; then
    echo "invalid rebuild_on for $(basename "$pkgdir"): must be an array of package names"
    return 1
  fi

  if ! jq -e '
    def version_map:
      type == "object" and (to_entries | all(.value | type == "string" and length > 0));
    (.rebuilt_against // {}) as $record |
    ($record | version_map) or
      (($record | type) == "object"
       and ((($record | keys) - ["x86_64", "aarch64"]) | length == 0)
       and ($record | to_entries | all(.value | version_map)))
  ' "$metadata" >/dev/null; then
    echo "invalid rebuilt_against for $(basename "$pkgdir"): must map architectures to package-version maps"
    return 1
  fi

  if ! jq -e '
    (.rebuild_on // []) as $triggers |
    (.rebuilt_against // {}) as $record |
    if ($record | to_entries | all(.value | type == "string")) then
      ((($record | keys) - $triggers) | length == 0)
    else
      ($record | to_entries | all((((.value | keys) - $triggers) | length) == 0))
    end
  ' "$metadata" >/dev/null; then
    echo "invalid rebuilt_against for $(basename "$pkgdir"): records a package that rebuild_on does not name"
    return 1
  fi
}
