#!/bin/bash
# OPR advisory sidecar regression test (omacom/omarchy-pkgs#378).
#
# Verifies the v1 contract:
# - sidecar lives beside the repo db and validates
# - refresh updates the sidecar without touching package archives
# - new CVE -> sidecar updates, package file unchanged
# - missing/stale/error are first-class and fail-open (never block)
# - no safety_score, no capability tags, severity always states its scale
#
# Uses a synthetic channel database in isolated temporary state: the fixture
# is a minimal tar with the same */desc record layout repo-add writes, which
# is the only thing bin/sync-advisories parses. No network, no Docker,
# no fixed delays.

set -euo pipefail

ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# shellcheck source=../helpers/advisory-helpers.sh
source "$ROOT/helpers/advisory-helpers.sh"

REPO_ROOT_TMP="$work/repo"
FEED="$work/feed"
mkdir -p "$REPO_ROOT_TMP/edge/x86_64" "$FEED"
export OMARCHY_REPO_ROOT="$REPO_ROOT_TMP"

REPO_DIR_TMP="$REPO_ROOT_TMP/edge/x86_64"
DB="$REPO_DIR_TMP/omarchy.db.tar.zst"

make_db() {
  local staging="$work/db-stage"
  rm -rf "$staging"
  mkdir -p "$staging/mise-bin" "$staging/other-pkg"
  cat >"$staging/mise-bin/desc" <<EOF
%FILENAME%
mise-bin-1.0.0-1-x86_64.pkg.tar.zst
%NAME%
mise-bin
%VERSION%
1.0.0-1
%ARCH%
x86_64
EOF
  cat >"$staging/other-pkg/desc" <<EOF
%FILENAME%
other-pkg-2.0.0-1-x86_64.pkg.tar.zst
%NAME%
other-pkg
%VERSION%
2.0.0-1
%ARCH%
x86_64
EOF
  tar -C "$staging" -cf "$DB" mise-bin other-pkg
}

# Package archives whose bytes must never change during a refresh.
printf 'mise package bytes\n' >"$REPO_DIR_TMP/mise-bin-1.0.0-1-x86_64.pkg.tar.zst"
printf 'other package bytes\n' >"$REPO_DIR_TMP/other-pkg-2.0.0-1-x86_64.pkg.tar.zst"
mise_before=$(sha256sum "$REPO_DIR_TMP/mise-bin-1.0.0-1-x86_64.pkg.tar.zst" | awk '{print $1}')
other_before=$(sha256sum "$REPO_DIR_TMP/other-pkg-2.0.0-1-x86_64.pkg.tar.zst" | awk '{print $1}')

make_db

# First ingest: mise-bin has two CVEs, other-pkg has no feed (missing).
cat >"$FEED/mise-bin.json" <<EOF
{
  "cve_ids": ["CVE-2026-0001", "CVE-2026-0002"],
  "cve_max_severity": "HIGH",
  "severity_scale": "CVSSv3",
  "advisory_as_of": "2026-09-10T00:00:00Z",
  "scan_source": "osv.dev"
}
EOF

"$ROOT/bin/sync-advisories" --mirror edge --arch x86_64 \
  --feed "$FEED" --no-sign --stale-after 720h >/dev/null

SIDECAR="$REPO_DIR_TMP/omarchy.advisories.json"
[[ -f $SIDECAR ]] || {
  echo "sidecar was not written beside the repo db" >&2
  exit 1
}
advisory_validate_sidecar "$SIDECAR"

[[ $(jq -r '.schema' "$SIDECAR") == 1 ]] || {
  echo "sidecar schema is not v1" >&2
  exit 1
}
[[ $(jq -r '.advisories["mise-bin"].scan_status' "$SIDECAR") == ok ]] || {
  echo "mise-bin should scan ok" >&2
  exit 1
}
[[ $(jq -r '.advisories["mise-bin"].cve_ids | length' "$SIDECAR") -eq 2 ]] || {
  echo "mise-bin should list two CVEs" >&2
  exit 1
}
[[ $(jq -r '.advisories["mise-bin"].severity_scale' "$SIDECAR") == CVSSv3 ]] || {
  echo "severity scale must be stated" >&2
  exit 1
}
[[ $(jq -r '.advisories["mise-bin"].pkgver' "$SIDECAR") == 1.0.0 ]] || {
  echo "entry must pin the published pkgver" >&2
  exit 1
}
[[ $(jq -r '.advisories["other-pkg"].scan_status' "$SIDECAR") == missing ]] || {
  echo "unscanned package should be missing, not an error" >&2
  exit 1
}

# Banned v1 fields must never appear.
if jq -e '.. | objects | has("safety_score") or has("capabilities") or has("ports")' \
  "$SIDECAR" >/dev/null; then
  echo "sidecar must not contain a safety score or capability tags" >&2
  exit 1
fi

# Demo: a new CVE lands. Only the sidecar changes; package bytes do not.
cat >"$FEED/mise-bin.json" <<EOF
{
  "cve_ids": ["CVE-2026-0001", "CVE-2026-0002", "CVE-2026-0003"],
  "cve_max_severity": "CRITICAL",
  "severity_scale": "CVSSv3",
  "advisory_as_of": "2026-09-11T00:00:00Z",
  "scan_source": "osv.dev"
}
EOF
sidecar_before=$(sha256sum "$SIDECAR" | awk '{print $1}')
"$ROOT/bin/sync-advisories" --mirror edge --arch x86_64 \
  --feed "$FEED" --no-sign --stale-after 720h >/dev/null
sidecar_after=$(sha256sum "$SIDECAR" | awk '{print $1}')
[[ $sidecar_before != "$sidecar_after" ]] || {
  echo "new CVE did not update the sidecar" >&2
  exit 1
}
[[ $(jq -r '.advisories["mise-bin"].cve_ids | length' "$SIDECAR") -eq 3 ]] || {
  echo "sidecar did not pick up the new CVE" >&2
  exit 1
}
[[ $(sha256sum "$REPO_DIR_TMP/mise-bin-1.0.0-1-x86_64.pkg.tar.zst" | awk '{print $1}') == "$mise_before" ]] || {
  echo "refresh rewrote the package archive" >&2
  exit 1
}
[[ $(sha256sum "$REPO_DIR_TMP/other-pkg-2.0.0-1-x86_64.pkg.tar.zst" | awk '{print $1}') == "$other_before" ]] || {
  echo "refresh rewrote an unrelated package archive" >&2
  exit 1
}

# Stale: an old advisory_as_of beyond the window reads stale, still fail-open.
cat >"$FEED/mise-bin.json" <<EOF
{
  "cve_ids": [],
  "cve_max_severity": "NONE",
  "severity_scale": "CVSSv3",
  "advisory_as_of": "2020-01-01T00:00:00Z",
  "scan_source": "osv.dev"
}
EOF
"$ROOT/bin/sync-advisories" --mirror edge --arch x86_64 \
  --feed "$FEED" --no-sign --stale-after 72h >/dev/null
[[ $(jq -r '.advisories["mise-bin"].scan_status' "$SIDECAR") == stale ]] || {
  echo "old scan should read stale" >&2
  exit 1
}

# Error, still fail-open: malformed feed.
printf '{not json' >"$FEED/mise-bin.json"
"$ROOT/bin/sync-advisories" --mirror edge --arch x86_64 \
  --feed "$FEED" --no-sign --stale-after 72h >/dev/null
[[ $(jq -r '.advisories["mise-bin"].scan_status' "$SIDECAR") == error ]] || {
  echo "malformed feed should read error" >&2
  exit 1
}

# Error: severity without a scale.
cat >"$FEED/mise-bin.json" <<EOF
{
  "cve_ids": ["CVE-2026-0001"],
  "cve_max_severity": "HIGH",
  "severity_scale": "",
  "advisory_as_of": "2026-09-11T00:00:00Z",
  "scan_source": "osv.dev"
}
EOF
"$ROOT/bin/sync-advisories" --mirror edge --arch x86_64 \
  --feed "$FEED" --no-sign --stale-after 720h >/dev/null
[[ $(jq -r '.advisories["mise-bin"].scan_status' "$SIDECAR") == error ]] || {
  echo "severity without a scale should read error" >&2
  exit 1
}
advisory_validate_sidecar "$SIDECAR"

# Filtered refresh preserves entries it did not ask about.
cat >"$FEED/mise-bin.json" <<EOF
{
  "cve_ids": [],
  "cve_max_severity": "NONE",
  "severity_scale": "CVSSv3",
  "advisory_as_of": "2026-09-11T00:00:00Z",
  "scan_source": "osv.dev"
}
EOF
"$ROOT/bin/sync-advisories" --mirror edge --arch x86_64 \
  --feed "$FEED" --no-sign --stale-after 720h >/dev/null
"$ROOT/bin/sync-advisories" --mirror edge --arch x86_64 --package mise-bin \
  --feed "$FEED" --no-sign --stale-after 720h >/dev/null
[[ $(jq -r '.advisories["other-pkg"].scan_status' "$SIDECAR") == missing ]] || {
  echo "filtered refresh dropped an unrequested entry" >&2
  exit 1
}

echo "PASS: OPR advisory sidecar refreshes without a rebuild (missing/stale/error fail-open)"
