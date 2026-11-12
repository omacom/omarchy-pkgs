#!/bin/bash
# Self-test for helpers/fast-ring-slots.jq: the fast-ring catch-up's slots,
# as the publish record and the PR comment read them. Needs jq.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; echo "$out"; exit 1; }

plan() { # plan <name> <from> <to> <action>
  jq -nc --arg n "$1" --arg f "$2" --arg t "$3" --arg a "$4" \
    '{type: "plan", arch: "aarch64", base: $n, name: $n, from_version: $f, to_version: $t, file: "\($n)-\($f)-any.pkg.tar.zst", size: 10, action: $a, reason: null}'
}
slot() { # slot <mirror> <status> <file stem>...
  local mirror=$1 status=$2; shift 2
  jq -nc --arg m "$mirror" --arg s "$status" '{type: "slot", mirror: $m, arch: "aarch64", status: $s, packages: $ARGS.positional}' --args "$@"
}

# rc in two batches, the second failing, then stable in one.
out=$({
  plan alpha 1.0-3 1.0-2 promote; plan beta 2.0-1 1.9-1 promote; plan gamma 1.0-1 "" hold
  slot rc published alpha-1.0-3-any
  slot rc failed beta-2.0-1-any
  plan alpha 1.0-3 1.0-1 promote
  slot stable published alpha-1.0-3-any
} | jq -sc -f "$ROOT/helpers/fast-ring-slots.jq" | jq -sc '[.[] | "\(.mirror) \(.status): " + ([.entries[] | "\(.name) \(.was)->\(.version) \(.status)"] | join(", "))]')

[[ $(jq -r '.[0]' <<<"$out") == "rc published: alpha 1.0-2->1.0-3 published" ]] \
  && [[ $(jq -r '.[1]' <<<"$out") == "rc failed: beta 1.9-1->2.0-1 failed" ]] \
  && pass "each batch carries only its own files, with its own status" || fail "batches"
[[ $(jq -r '.[2]' <<<"$out") == "stable published: alpha 1.0-1->1.0-3 published" ]] \
  && pass "a second run's slot takes that run's plan, not the first's" || fail "runs"
