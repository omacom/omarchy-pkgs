#!/bin/bash
# OPR advisory sidecar helpers (omacom/omarchy-pkgs#378).
#
# The sidecar is OPR-published metadata, not PKGBUILD content: it answers
# "which known CVEs apply to this published version, and how fresh is that
# answer?" by ingesting existing CVE sources. OPR does not scan the
# package. A version with no source report yet is missing, fail-open.
#
# Location: beside the pacman database in every channel/arch tree:
#   pkgs.omarchy.org/<channel>/<arch>/omarchy.advisories.json (+ .sig)
#
# Schema v1 (no safety_score, no capability tags; those would be a
# separate app/repo if they ever exist):
#   {
#     "schema": 1, "channel": "edge", "arch": "x86_64",
#     "generated_at": "<UTC ISO-8601>",
#     "advisories": {
#       "<pkgname>:<pkgver>-<pkgrel>:<arch>": {
#         "pkgname": "pkgname",
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
# Keying: pkgname:pkgver-pkgrel:arch. The value repeats those fields plus
# artifact. A feed for another version does not stamp the live package.
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
    (.advisories // {}) | to_entries | all(
      (.value.pkgname | type == "string") and
      (.value.pkgver | type == "string") and
      (.value.pkgrel | type == "string") and
      (.value.arch | type == "string") and
      (.key == (.value.pkgname + ":" + .value.pkgver + "-" + .value.pkgrel + ":" + .value.arch)) and
      ((.value.cve_ids // null) == null or (.value.cve_ids | type == "array")) and
      ((.value.cve_max_severity // null) == null or (.value.cve_max_severity | type == "string")) and
      ((.value.scan_status // "") | IN("ok", "stale", "missing", "error")) and
      (if .value.scan_status == "error" then true
       elif (.value.cve_max_severity // "NONE") == "NONE" then true
       else ((.value.severity_scale // "") | length > 0) end) and
      (if (.value.scan_status == "ok" or .value.scan_status == "stale")
       then ((.value.scanned_at // "") | length > 0) else true end)
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
