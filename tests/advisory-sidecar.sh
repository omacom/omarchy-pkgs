#!/bin/bash
# OPR advisory sidecar regression test (omacom/omarchy-pkgs#378).
#
# Verifies the v1 contract:
# - sidecar lives beside the repo db and validates
# - entries are keyed by pkgname:pkgver-pkgrel:arch
# - a feed for another version does not stamp the live package
# - two versions of one name keep two rows
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

MISE_KEY="mise-bin:1.0.0-1:x86_64"
OTHER_KEY="other-pkg:2.0.0-1:x86_64"
MISE_V2_KEY="mise-bin:2.0.0-1:x86_64"

write_feed() {
  local name="$1" pkgver="$2" pkgrel="$3" arch="$4"
  local dest="$FEED/$name/${pkgver}-${pkgrel}/${arch}.json"
  mkdir -p "$(dirname "$dest")"
  cat >"$dest"
}

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

# First ingest: mise-bin 1.0.0-1 has two CVEs, other-pkg has no feed (missing).
write_feed mise-bin 1.0.0 1 x86_64 <<EOF
{
  "pkgname": "mise-bin",
  "pkgver": "1.0.0",
  "pkgrel": "1",
  "arch": "x86_64",
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
[[ $(jq -r --arg k "$MISE_KEY" '.advisories[$k].scan_status' "$SIDECAR") == ok ]] || {
  echo "mise-bin 1.0.0-1 should scan ok" >&2
  exit 1
}
[[ $(jq -r --arg k "$MISE_KEY" '.advisories[$k].pkgname' "$SIDECAR") == mise-bin ]] || {
  echo "entry must name the package" >&2
  exit 1
}
[[ $(jq -r --arg k "$MISE_KEY" '.advisories[$k].cve_ids | length' "$SIDECAR") -eq 2 ]] || {
  echo "mise-bin should list two CVEs" >&2
  exit 1
}
[[ $(jq -r --arg k "$MISE_KEY" '.advisories[$k].severity_scale' "$SIDECAR") == CVSSv3 ]] || {
  echo "severity scale must be stated" >&2
  exit 1
}
[[ $(jq -r --arg k "$MISE_KEY" '.advisories[$k].pkgver' "$SIDECAR") == 1.0.0 ]] || {
  echo "entry must pin the published pkgver" >&2
  exit 1
}
if jq -e '.advisories | has("mise-bin")' "$SIDECAR" >/dev/null; then
  echo "sidecar must not key entries by package name alone" >&2
  exit 1
fi
[[ $(jq -r --arg k "$OTHER_KEY" '.advisories[$k].scan_status' "$SIDECAR") == missing ]] || {
  echo "unscanned package should be missing, not an error" >&2
  exit 1
}

# Banned v1 fields must never appear.
if jq -e '.. | objects | has("safety_score") or has("capabilities") or has("ports")' \
  "$SIDECAR" >/dev/null; then
  echo "sidecar must not contain a safety score or capability tags" >&2
  exit 1
fi

# A feed for another version must not stamp the live package.
write_feed mise-bin 9.9.9 1 x86_64 <<EOF
{
  "pkgname": "mise-bin",
  "pkgver": "9.9.9",
  "pkgrel": "1",
  "arch": "x86_64",
  "cve_ids": ["CVE-2026-9999"],
  "cve_max_severity": "CRITICAL",
  "severity_scale": "CVSSv3",
  "advisory_as_of": "2026-09-11T00:00:00Z",
  "scan_source": "osv.dev"
}
EOF
rm -f "$FEED/mise-bin/1.0.0-1/x86_64.json"
"$ROOT/bin/sync-advisories" --mirror edge --arch x86_64 \
  --feed "$FEED" --no-sign --stale-after 720h >/dev/null
[[ $(jq -r --arg k "$MISE_KEY" '.advisories[$k].scan_status' "$SIDECAR") == missing ]] || {
  echo "a feed for 9.9.9 must not stamp live 1.0.0-1" >&2
  exit 1
}
if jq -e --arg k "$MISE_KEY" '.advisories[$k].cve_ids | index("CVE-2026-9999")' "$SIDECAR" >/dev/null; then
  echo "mismatched feed CVE leaked onto the live package" >&2
  exit 1
fi

# Restore a matching feed for the rest of the suite.
write_feed mise-bin 1.0.0 1 x86_64 <<EOF
{
  "pkgname": "mise-bin",
  "pkgver": "1.0.0",
  "pkgrel": "1",
  "arch": "x86_64",
  "cve_ids": ["CVE-2026-0001", "CVE-2026-0002"],
  "cve_max_severity": "HIGH",
  "severity_scale": "CVSSv3",
  "advisory_as_of": "2026-09-10T00:00:00Z",
  "scan_source": "osv.dev"
}
EOF

# Demo: a new CVE lands. Only the sidecar changes; package bytes do not.
write_feed mise-bin 1.0.0 1 x86_64 <<EOF
{
  "pkgname": "mise-bin",
  "pkgver": "1.0.0",
  "pkgrel": "1",
  "arch": "x86_64",
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
[[ $(jq -r --arg k "$MISE_KEY" '.advisories[$k].cve_ids | length' "$SIDECAR") -eq 3 ]] || {
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
write_feed mise-bin 1.0.0 1 x86_64 <<EOF
{
  "pkgname": "mise-bin",
  "pkgver": "1.0.0",
  "pkgrel": "1",
  "arch": "x86_64",
  "cve_ids": [],
  "cve_max_severity": "NONE",
  "severity_scale": "CVSSv3",
  "advisory_as_of": "2020-01-01T00:00:00Z",
  "scan_source": "osv.dev"
}
EOF
"$ROOT/bin/sync-advisories" --mirror edge --arch x86_64 \
  --feed "$FEED" --no-sign --stale-after 72h >/dev/null
[[ $(jq -r --arg k "$MISE_KEY" '.advisories[$k].scan_status' "$SIDECAR") == stale ]] || {
  echo "old scan should read stale" >&2
  exit 1
}

# Error, still fail-open: malformed feed.
printf '{not json' >"$FEED/mise-bin/1.0.0-1/x86_64.json"
"$ROOT/bin/sync-advisories" --mirror edge --arch x86_64 \
  --feed "$FEED" --no-sign --stale-after 72h >/dev/null
[[ $(jq -r --arg k "$MISE_KEY" '.advisories[$k].scan_status' "$SIDECAR") == error ]] || {
  echo "malformed feed should read error" >&2
  exit 1
}

# Error: severity without a scale.
write_feed mise-bin 1.0.0 1 x86_64 <<EOF
{
  "pkgname": "mise-bin",
  "pkgver": "1.0.0",
  "pkgrel": "1",
  "arch": "x86_64",
  "cve_ids": ["CVE-2026-0001"],
  "cve_max_severity": "HIGH",
  "severity_scale": "",
  "advisory_as_of": "2026-09-11T00:00:00Z",
  "scan_source": "osv.dev"
}
EOF
"$ROOT/bin/sync-advisories" --mirror edge --arch x86_64 \
  --feed "$FEED" --no-sign --stale-after 720h >/dev/null
[[ $(jq -r --arg k "$MISE_KEY" '.advisories[$k].scan_status' "$SIDECAR") == error ]] || {
  echo "severity without a scale should read error" >&2
  exit 1
}
advisory_validate_sidecar "$SIDECAR"

# Filtered refresh preserves entries it did not ask about.
write_feed mise-bin 1.0.0 1 x86_64 <<EOF
{
  "pkgname": "mise-bin",
  "pkgver": "1.0.0",
  "pkgrel": "1",
  "arch": "x86_64",
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
[[ $(jq -r --arg k "$OTHER_KEY" '.advisories[$k].scan_status' "$SIDECAR") == missing ]] || {
  echo "filtered refresh dropped an unrequested entry" >&2
  exit 1
}

# Two versions of the same name keep two rows.
mkdir -p "$work/db-stage/mise-bin" "$work/db-stage/mise-bin-v2" "$work/db-stage/other-pkg"
cat >"$work/db-stage/mise-bin-v2/desc" <<EOF
%FILENAME%
mise-bin-2.0.0-1-x86_64.pkg.tar.zst
%NAME%
mise-bin
%VERSION%
2.0.0-1
%ARCH%
x86_64
EOF
tar -C "$work/db-stage" -cf "$DB" mise-bin mise-bin-v2 other-pkg
printf 'mise v2 bytes\n' >"$REPO_DIR_TMP/mise-bin-2.0.0-1-x86_64.pkg.tar.zst"
write_feed mise-bin 2.0.0 1 x86_64 <<EOF
{
  "pkgname": "mise-bin",
  "pkgver": "2.0.0",
  "pkgrel": "1",
  "arch": "x86_64",
  "cve_ids": ["CVE-2026-2000"],
  "cve_max_severity": "LOW",
  "severity_scale": "CVSSv3",
  "advisory_as_of": "2026-09-11T00:00:00Z",
  "scan_source": "osv.dev"
}
EOF
"$ROOT/bin/sync-advisories" --mirror edge --arch x86_64 \
  --feed "$FEED" --no-sign --stale-after 720h >/dev/null
[[ $(jq -r --arg k "$MISE_KEY" '.advisories[$k].pkgver' "$SIDECAR") == 1.0.0 ]] || {
  echo "version 1.0.0-1 must keep its own row" >&2
  exit 1
}
[[ $(jq -r --arg k "$MISE_V2_KEY" '.advisories[$k].pkgver' "$SIDECAR") == 2.0.0 ]] || {
  echo "version 2.0.0-1 must keep its own row" >&2
  exit 1
}
[[ $(jq -r --arg k "$MISE_V2_KEY" '.advisories[$k].cve_ids[0]' "$SIDECAR") == CVE-2026-2000 ]] || {
  echo "version 2.0.0-1 must keep its own CVEs" >&2
  exit 1
}

echo "PASS: OPR advisory sidecar refreshes without a rebuild (missing/stale/error fail-open)"
