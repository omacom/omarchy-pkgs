#!/bin/bash
# OPR advisory sidecar helpers (omacom/omarchy-pkgs#378).
#
# The sidecar is OPR-published metadata, not PKGBUILD content: it answers
# "which known CVEs apply to this published version, and how fresh is that
# answer?" without rebuilding the package.
#
# Location: beside the pacman database in every channel/arch tree:
#   pkgs.omarchy.org/<channel>/<arch>/omarchy.advisories.json (+ .sig)
#
# Schema v1 (no safety_score, no capability tags):
#   {
#     "schema": 1, "channel": "edge", "arch": "x86_64",
#     "generated_at": "<UTC ISO-8601>",
#     "advisories": {
#       "<pkgname>": {
#         "pkgver": "1.2.3", "pkgrel": "1", "arch": "x86_64",
#         "artifact": "pkgname-1.2.3-1-x86_64.pkg.tar.zst",
#         "cve_ids": ["CVE-2026-0001"],
#         "cve_max_severity": "HIGH", "severity_scale": "CVSSv3",
#         "advisory_as_of": "<UTC ISO-8601>", "scanned_at": "<UTC ISO-8601>",
#         "scan_source": "osv.dev",
#         "scan_status": "ok|stale|missing|error",
#         "note": "optional human-readable context"
#       }
#     }
#   }
#
# Keying: entries are keyed by package name; each entry pins pkgver/pkgrel/
# arch/artifact so a reader can tell the scan belongs to the installed
# version. A version change without a rescan reads as stale/missing, never
# as clean.
#
# Writer: OPR-operated ingest only (bin/sync-advisories). Maintainers must
# not write CVE data in .omarchy/package.json or the PKGBUILD. The sidecar
# is detached-signed with the same OPR repo key that signs packages.
#
# Policy: missing/stale is first-class. Default is visible + warn
# (fail-open); a client may opt into fail-closed. The resolver must only
# print an OPR advisory band for OPR built-here artifacts, never for
# brew/flatpak/apt routes.

ADVISORY_SIDECAR_NAME="omarchy.advisories.json"
ADVISORY_SCHEMA_VERSION=1
ADVISORY_VALID_STATUSES="ok stale missing error"

advisory_sidecar_path() {
  local repo_dir="${1:-${REPO_DIR:-}}"
  [[ -n "$repo_dir" ]] || return 1
  echo "$repo_dir/$ADVISORY_SIDECAR_NAME"
}

advisory_valid_status() {
  case "$1" in
  ok | stale | missing | error) return 0 ;;
  *) return 1 ;;
  esac
}

# Validate a sidecar file. Prints an error and returns 1 when invalid.
advisory_validate_sidecar() {
  local sidecar="$1"
  [[ -f "$sidecar" ]] || {
    echo "advisory sidecar not found: $sidecar" >&2
    return 1
  }
  jq -e --argjson schema "$ADVISORY_SCHEMA_VERSION" \
    '.schema == $schema and (.advisories | type == "object")' \
    "$sidecar" >/dev/null || {
    echo "advisory sidecar has unsupported schema: $sidecar" >&2
    return 1
  }
  # Every entry must carry the v1 fields with a known status; severity scale
  # must be stated whenever a severity is claimed (error entries record the
  # malformed report verbatim for triage, so they are exempt).
  jq -e '
    (.advisories // {}) | to_entries | map(.value) | all(
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
    )
  ' "$sidecar" >/dev/null || {
    echo "advisory sidecar failed v1 validation: $sidecar" >&2
    return 1
  }
}

# Empty sidecar skeleton for a channel/arch pair.
advisory_empty_sidecar() {
  local channel="$1" arch="$2" generated_at="$3"
  jq -n --arg channel "$channel" --arg arch "$arch" --arg generated_at "$generated_at" \
    --argjson schema "$ADVISORY_SCHEMA_VERSION" \
    '{schema: $schema, channel: $channel, arch: $arch,
      generated_at: $generated_at, advisories: {}}'
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
