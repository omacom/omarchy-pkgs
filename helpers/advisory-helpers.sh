#!/bin/bash
# OPR advisory sidecar helpers (omacom/omarchy-pkgs#378).
#
# The sidecar is OPR-published metadata, not PKGBUILD content: it answers
# "which known CVEs apply to this published version, and how fresh is that
# answer?" by ingesting existing CVE sources. OPR does not scan the
# package. A version with no source report yet is missing, fail-open.
#
# Location: one file per published artifact, beside that package archive:
#   pkgs.omarchy.org/<channel>/<arch>/<pkgname>-<pkgver>-<pkgrel>-<arch>.advisory.json
#   plus a detached .sig
#
# A new package adds one file. A refresh replaces that file and leaves every
# other advisory file alone. A missing file means scan_status=missing.
#
# Schema v1 (no safety_score, no capability tags; those would be a
# separate app/repo if they ever exist). Each file is one artifact:
#   {
#     "schema": 1,
#     "pkgname": "pkgname",
#     "pkgver": "1.2.3", "pkgrel": "1", "arch": "x86_64",
#     "artifact": "pkgname-1.2.3-1-x86_64.pkg.tar.zst",
#     "cve_ids": ["CVE-2026-0001"],
#     "cve_max_severity": "HIGH", "severity_scale": "CVSSv3",
#     "advisory_as_of": "<UTC ISO-8601>", "scanned_at": "<UTC ISO-8601>",
#     "scan_source": "osv.dev",
#     "scan_status": "ok|stale|missing|error",
#     "note": "optional human-readable context"
#   }
#
# The filename is the key: pkgname-pkgver-pkgrel-arch. A feed for another
# version does not stamp the live package.
#
# Writer: OPR-operated ingest only (bin/sync-advisories). Maintainers must
# not write CVE data in .omarchy/package.json or the PKGBUILD. The sidecar
# is detached-signed with the same OPR repo key that signs packages.
#
# Policy: missing/stale is first-class. Default is visible + warn
# (fail-open); a client may opt into fail-closed. The resolver must only
# print an OPR advisory band for OPR built-here artifacts, never for
# brew/flatpak/apt routes.

ADVISORY_SCHEMA_VERSION=1
ADVISORY_VALID_STATUSES="ok stale missing error"

# Published filename for one artifact, without the directory.
advisory_artifact_name() {
  local name="$1" pkgver="$2" pkgrel="$3" arch="$4"
  echo "${name}-${pkgver}-${pkgrel}-${arch}.advisory.json"
}

advisory_artifact_path() {
  local repo_dir="$1" name="$2" pkgver="$3" pkgrel="$4" arch="$5"
  echo "$repo_dir/$(advisory_artifact_name "$name" "$pkgver" "$pkgrel" "$arch")"
}

# <repo>/<pkgfile-without-.pkg.tar.*>.advisory.json beside the package archive.
advisory_path_for_package_file() {
  local repo_dir="$1" filename="$2"
  local stem="${filename%.pkg.tar.*}"
  echo "$repo_dir/${stem}.advisory.json"
}

advisory_valid_status() {
  case "$1" in
  ok | stale | missing | error) return 0 ;;
  *) return 1 ;;
  esac
}

# Identity used as the sidecar object key and the feed path stem.
advisory_identity_key() {
  local name="$1" pkgver="$2" pkgrel="$3" arch="$4"
  echo "${name}:${pkgver}-${pkgrel}:${arch}"
}

# Feed file for one published artifact: <feed>/<pkgname>/<pkgver>-<pkgrel>/<arch>.json
advisory_feed_path() {
  local feed_dir="$1" name="$2" pkgver="$3" pkgrel="$4" arch="$5"
  echo "${feed_dir}/${name}/${pkgver}-${pkgrel}/${arch}.json"
}

# Validate one artifact advisory file. Prints an error and returns 1 when invalid.
advisory_validate_sidecar() {
  local sidecar="$1"
  [[ -f "$sidecar" ]] || {
    echo "advisory file not found: $sidecar" >&2
    return 1
  }
  # Severity scale must be stated whenever a severity is claimed. Error
  # entries record the malformed report for triage, so they are exempt.
  jq -e --argjson schema "$ADVISORY_SCHEMA_VERSION" '
    .schema == $schema and
    (.pkgname | type == "string") and
    (.pkgver | type == "string") and
    (.pkgrel | type == "string") and
    (.arch | type == "string") and
    ((.cve_ids // null) == null or (.cve_ids | type == "array")) and
    ((.cve_max_severity // null) == null or (.cve_max_severity | type == "string")) and
    ((.scan_status // "") | IN("ok", "stale", "missing", "error")) and
    (if .scan_status == "error" then true
     elif (.cve_max_severity // "NONE") == "NONE" then true
     else ((.severity_scale // "") | length > 0) end) and
    (if (.scan_status == "ok" or .scan_status == "stale")
     then ((.scanned_at // "") | length > 0) else true end)
  ' "$sidecar" >/dev/null || {
    echo "advisory file failed v1 validation: $sidecar" >&2
    return 1
  }
}

# Duration to seconds: bare seconds or s/m/h/d suffix (mirrors
# package_min_release_age_seconds conventions).
advisory_duration_seconds() {
  local raw="$1"
  [[ "$raw" =~ ^([0-9]{1,9})([smhd]?)$ ]] || return 1
  local n=$((10#${BASH_REMATCH[1]}))
  case "${BASH_REMATCH[2]}" in
  "" | s) echo "$n" ;;
  m) echo $((n * 60)) ;;
  h) echo $((n * 3600)) ;;
  d) echo $((n * 86400)) ;;
  esac
}
