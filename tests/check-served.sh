#!/bin/bash
# Self-test for bin/check-served: does the channel, as users read it, list
# what the publish wrote? Channel databases come from a local directory
# (file://). Needs jq, curl and GNU tar with zstd.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; cat "$T/out" "$T/record.json" 2>/dev/null; exit 1; }

channel() { # channel <channel> <arch> <name-version-rel>...
  local dir="$T/channels/$1/$2"; shift 2
  mkdir -p "$dir"; rm -rf "$T/db"; mkdir -p "$T/db"
  for entry in "$@"; do mkdir -p "$T/db/$entry"; done
  (cd "$T/db" && tar --zstd -cf "$dir/omarchy.db" -- *)
}
record() { # record <target> <slots json>
  jq -n --arg target "$1" --argjson slots "$2" '{target: $target, slots: $slots, sources: [], plan: []}' > "$T/record.json"
}
check() { "$ROOT/bin/check-served" --channels "file://$T/channels" --tries 2 --wait 0 "$T/record.json" > "$T/out" 2>&1; }

channel edge x86_64 alpha-1.0-3 beta-1.0-1
channel edge aarch64 alpha-1.0-2

slots='[{"mirror": "edge", "arch": "x86_64", "status": "published", "packages": ["alpha-1.0-3-any", "beta-1.0-1-x86_64"]},
        {"mirror": "rc", "arch": "x86_64", "status": "not-run", "packages": ["alpha-1.0-3-any"]}]'
record live "$slots"
check && jq -e '.slots[0].served | .ok and .tries == 1 and .missing == []' "$T/record.json" >/dev/null \
  && jq -e '.slots[1] | has("served") | not' "$T/record.json" >/dev/null \
  && pass "a slot whose channel lists every file is served; a slot that did not run is not checked" || fail "served slot"

# edge/aarch64 still lists the old alpha: the bucket got the files, users did not.
record live '[{"mirror": "edge", "arch": "aarch64", "status": "published", "packages": ["alpha-1.0-3-any"]}]'
if check; then fail "a missing entry must fail"; fi
jq -e '.slots[0].served | (.ok | not) and .tries == 2 and .missing == ["alpha-1.0-3"]' "$T/record.json" >/dev/null \
  && grep -q 'does not serve alpha-1.0-3 after 2 tries' "$T/out" \
  && pass "a channel that does not list a published file fails, after every try" || fail "unserved slot"

# A rerun of that slot finds the bucket ahead and skips the file: the slot is
# unchanged, but the channel must still list the version the bucket has.
record live '[{"mirror": "edge", "arch": "aarch64", "status": "unchanged", "packages": [],
  "entries": [{"name": "alpha", "version": "1.0-3", "was": "1.0-3", "status": "skipped"}]}]'
if check; then fail "a rerun must not pass while the channel still lacks the file"; fi
jq -e '.slots[0].served.missing == ["alpha-1.0-3"]' "$T/record.json" >/dev/null \
  && pass "a rerun that wrote nothing still checks what the bucket serves" || fail "unchanged slot"

# The catch-up in the same run replaced rc's alpha 1.0-2 with edge's 1.0-3:
# only the later slot's entry is what the channel must list.
channel rc aarch64 alpha-1.0-3
record live '[{"mirror": "rc", "arch": "aarch64", "status": "published", "packages": [],
    "entries": [{"name": "alpha", "version": "1.0-2", "was": "1.0-1", "status": "published"}]},
  {"mirror": "rc", "arch": "aarch64", "status": "published", "packages": ["alpha-1.0-3-any"],
    "entries": [{"name": "alpha", "version": "1.0-3", "was": "1.0-2", "status": "published"}]}]'
check && jq -e '[.slots[].served.ok] == [true, true]' "$T/record.json" >/dev/null \
  && pass "a package a later slot replaced is checked at the later version" || fail "superseded entry"

# A slot handed alpha 1.0-3 and an older 1.0-1 publishes the one and skips
# the other: only the published version is what the channel must list.
record live '[{"mirror": "rc", "arch": "aarch64", "status": "published", "packages": ["alpha-1.0-3-any"],
  "entries": [{"name": "alpha", "version": "1.0-3", "was": "1.0-2", "status": "published"},
              {"name": "alpha", "version": "1.0-1", "was": "1.0-2", "status": "skipped"}]}]'
check && jq -e '.slots[0].served.ok' "$T/record.json" >/dev/null \
  && pass "a skipped older copy of a published package is not expected" || fail "skipped beside published"

# A proof run writes a scratch prefix, not the public channels.
record proof-1 '[{"mirror": "edge", "arch": "aarch64", "status": "published", "packages": ["alpha-1.0-3-any"]}]'
check && jq -e '.slots[0] | has("served") | not' "$T/record.json" >/dev/null \
  && pass "a proof run is not checked against the public channels" || fail "proof run"
