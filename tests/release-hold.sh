#!/bin/bash
# A package on the unattended lane ships upstream releases nobody has read.
# Where the feed dates its releases, the recipe has to say how long a new one
# is held: "24h" for someone else's project, "0" for our own.
set -euo pipefail
BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
PKGBUILDS=${PKGBUILDS_DIR:-$BUILD_ROOT/pkgbuilds}

# Feeds whose releases carry a publish time the hold can be measured from.
undeclared() {
  local metadata
  for metadata in "$PKGBUILDS"/*/.omarchy/package.json; do
    jq -r --arg name "$(basename "$(dirname "$(dirname "$metadata")")")" '
      select(.auto_merge == true and (has("min_release_age") | not))
      | (.upstream // {}) | (.watch // .)
      | select(type == "object" and (has("github") or has("npm") or has("pypi") or has("git_branch")))
      | $name
    ' "$metadata" || { echo "cannot read $metadata" >&2; return 1; }
  done
}

# The rule itself, against fixtures, before it is trusted on the real recipes.
(
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  fixture() { mkdir -p "$T/$1/.omarchy"; printf '%s\n' "$2" > "$T/$1/.omarchy/package.json"; }
  fixture held        '{"source":"local","auto_merge":true,"min_release_age":"24h","upstream":{"watch":{"github":"o/p"}}}'
  fixture ours        '{"source":"local","auto_merge":true,"min_release_age":"0","upstream":{"watch":{"github":"omacom/p"}}}'
  fixture reviewed    '{"source":"local","upstream":{"watch":{"github":"o/p"}}}'
  fixture undated     '{"source":"local","auto_merge":true,"upstream":{"watch":{"debian":"https://example.com/Packages","package":"p"}}}'
  fixture hooked      '{"source":"local","auto_merge":true}'
  fixture watch-gh    '{"source":"local","auto_merge":true,"upstream":{"watch":{"github":"o/p"}}}'
  fixture provider-np '{"source":"local","auto_merge":true,"upstream":{"npm":"p"}}'
  fixture branch      '{"source":"local","auto_merge":true,"upstream":{"watch":{"git_branch":"https://example.com/p.git","branch":"main"}}}'
  got=$(PKGBUILDS=$T undeclared | sort | paste -sd' ')
  want="branch provider-np watch-gh"
  [[ "$got" == "$want" ]] || { printf 'FAIL: expected "%s", got "%s"\n' "$want" "$got"; exit 1; }
  echo "PASS: only unattended packages on a dated feed with no stated hold are flagged"
)

# Captured first, so a recipe jq cannot read fails the test instead of
# passing as "nothing missing".
found=$(undeclared) || { echo "FAIL: a recipe's metadata could not be read"; exit 1; }
if [[ -n "$found" ]]; then
  mapfile -t missing <<<"$found"
  printf 'FAIL: %s\n' "${missing[@]}"
  cat <<'MSG'

These packages have "auto_merge": true and a feed that dates its releases, but
no "min_release_age". Add one to .omarchy/package.json:
  "min_release_age": "24h"   someone else's project: hold a new release a day
  "min_release_age": "0"     our own project: ship at once
MSG
  exit 1
fi
echo "PASS: every unattended package on a dated feed states its release hold"
