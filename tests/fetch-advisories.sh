#!/bin/bash
# Producer for versioned advisory feed JSON (omacom/omarchy-pkgs#378).
# Stubs OSV HTTP. No live network.

set -euo pipefail

ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

REPO_ROOT_TMP="$work/repo"
FEED="$work/feed"
mkdir -p "$REPO_ROOT_TMP/edge/x86_64" "$FEED" "$work/bin"
export OMARCHY_REPO_ROOT="$REPO_ROOT_TMP"

REPO_DIR_TMP="$REPO_ROOT_TMP/edge/x86_64"
DB="$REPO_DIR_TMP/omarchy.db.tar.zst"

mkdir -p "$work/db-stage/mise-bin"
cat >"$work/db-stage/mise-bin/desc" <<EOF
%FILENAME%
mise-bin-1.0.0-1-x86_64.pkg.tar.zst
%NAME%
mise-bin
%VERSION%
1.0.0-1
%ARCH%
x86_64
EOF
tar -C "$work/db-stage" -cf "$DB" mise-bin
printf 'pkg\n' >"$REPO_DIR_TMP/mise-bin-1.0.0-1-x86_64.pkg.tar.zst"

cat >"$work/osv.json" <<'EOF'
{
  "vulns": [
    {
      "id": "GHSA-aaaa-bbbb-cccc",
      "aliases": ["CVE-2026-4242"],
      "severity": [{ "type": "CVSS_V3", "score": "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H" }]
    }
  ]
}
EOF

cat >"$work/bin/curl" <<EOF
#!/bin/bash
cat "\$OSV_STUB_RESPONSE"
EOF
chmod +x "$work/bin/curl"

cat >"$work/purls" <<'EOF'
mise-bin pkg:github/jdx/mise@{version}
EOF

OSV_STUB_RESPONSE="$work/osv.json" PATH="$work/bin:$PATH" \
  "$ROOT/bin/fetch-advisories" --mirror edge --arch x86_64 \
  --feed "$FEED" --purl-map "$work/purls" --package mise-bin >/dev/null

feed_file="$FEED/mise-bin/1.0.0-1/x86_64.json"
[[ -f $feed_file ]] || {
  echo "producer did not write a versioned feed file" >&2
  exit 1
}
[[ $(jq -r '.pkgver' "$feed_file") == 1.0.0 ]] || {
  echo "feed must pin pkgver" >&2
  exit 1
}
[[ $(jq -r '.pkgrel' "$feed_file") == 1 ]] || {
  echo "feed must pin pkgrel" >&2
  exit 1
}
[[ $(jq -r '.scan_source' "$feed_file") == osv.dev ]] || {
  echo "scan_source must be osv.dev" >&2
  exit 1
}
jq -e '.cve_ids | index("CVE-2026-4242")' "$feed_file" >/dev/null || {
  echo "producer must collect CVE ids from OSV aliases" >&2
  exit 1
}
[[ $(jq -r '.cve_max_severity' "$feed_file") == HIGH ]] || {
  echo "CVSS vector with Confidentiality/Integrity/Availability High should map to HIGH" >&2
  exit 1
}

"$ROOT/bin/sync-advisories" --mirror edge --arch x86_64 \
  --feed "$FEED" --no-sign --stale-after 720h >/dev/null

key="mise-bin:1.0.0-1:x86_64"
sidecar="$REPO_DIR_TMP/omarchy.advisories.json"
[[ $(jq -r --arg k "$key" '.advisories[$k].scan_status' "$sidecar") == ok ]] || {
  echo "ingest of produced feed should scan ok" >&2
  exit 1
}

pkg_hash=$(sha256sum "$REPO_DIR_TMP/mise-bin-1.0.0-1-x86_64.pkg.tar.zst" | awk '{print $1}')
[[ $(jq -r --arg k "$key" '.advisories[$k].cve_ids[0]' "$sidecar") == CVE-2026-4242 ]] || {
  echo "sidecar should carry the produced CVE" >&2
  exit 1
}
[[ $(sha256sum "$REPO_DIR_TMP/mise-bin-1.0.0-1-x86_64.pkg.tar.zst" | awk '{print $1}') == "$pkg_hash" ]] || {
  echo "producer+ingest rewrote the package archive" >&2
  exit 1
}

# Empty vulns means the source has no report yet: do not write a "clean" feed.
printf '{ "vulns": [] }\n' >"$work/osv-empty.json"
rm -f "$feed_file"
OSV_STUB_RESPONSE="$work/osv-empty.json" PATH="$work/bin:$PATH" \
  "$ROOT/bin/fetch-advisories" --mirror edge --arch x86_64 \
  --feed "$FEED" --purl-map "$work/purls" --package mise-bin >/dev/null
[[ ! -f $feed_file ]] || {
  echo "empty OSV vulns must not write a feed (row stays missing)" >&2
  exit 1
}

echo "PASS: fetch-advisories writes a version-pinned OSV feed without touching packages"
