#!/bin/bash
# Self-test for bin/publish-report: what the merged PR is told about a
# publish. Channel databases come from a local directory (file://).
# Needs jq, curl and GNU tar with zstd.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; cat "$T/out"; exit 1; }

# channel <channel> <arch> <name-version-rel>...: a database serving these.
channel() {
  local dir="$T/channels/$1/$2"; shift 2
  mkdir -p "$dir" "$T/db"; rm -rf "$T/db"/*
  for entry in "$@"; do mkdir -p "$T/db/$entry"; done
  # Entries at the top level, as repo-add writes them: no leading ./
  (cd "$T/db" && tar --zstd -cf "$dir/omarchy.db" -- *)
}
channel edge x86_64 alpha-1.0-2 beta-1.0-1
channel rc x86_64 alpha-1.0-1 beta-1.0-1
channel stable x86_64 alpha-1.0-1
channel edge aarch64 alpha-1.0-2
channel rc aarch64 alpha-1.0-1
channel stable aarch64 alpha-1.0-1
printf 'alpha 1.0-1\n' > "$T/inventory"

entry() { # entry <name> <version> <was> <status> [size was_size]
  jq -nc --arg n "$1" --arg v "$2" --arg w "$3" --arg s "$4" --argjson size "${5:-null}" --argjson was_size "${6:-null}" \
    '{name: $n, base: $n, version: $v, was: (if $w == "" then null else $w end), status: $s, size: $size, was_size: $was_size,
      file: "\($n)-\($v)-any"}'
}
record() { # record <sources json> <slots json> [plan json]
  jq -n --argjson sources "$1" --argjson slots "$2" --argjson plan "${3:-[]}" \
    '{time: "2026-11-12T09:24:06Z", commit: "cad67735c43ec596364c6925b681796f4a59a996",
      run: "https://github.com/omacom/omarchy-pkgs/actions/runs/1", event: "push", target: "live",
      plan: $plan, sources: $sources, slots: $slots}' > "$T/record.json"
}
report() { "$ROOT/bin/publish-report" --channels "file://$T/channels" --inventory "$T/inventory" "$@" "$T/record.json" > "$T/out" 2>&1; }
row() { grep -E "^\| $1 \|" "$T/out"; }

plan='[{"package": "alpha", "arch": "x86_64", "channels": "edge", "publish_arches": "x86_64 aarch64"},
       {"package": "beta", "arch": "x86_64", "channels": "edge", "publish_arches": "x86_64"}]'

# A merge of alpha 1.0-3 (arch=any) and beta 1.0-1, which edge already serves.
# beta was handed to the slot but skipped: it must not read as published.
record '[{"package": "alpha", "arch": "x86_64", "source": "pr-artifact"}, {"package": "beta", "arch": "x86_64", "source": "pr-artifact"}]' \
  "[{\"mirror\": \"edge\", \"arch\": \"x86_64\", \"status\": \"published\", \"signer\": \"0123456789ABCDEF0123456789ABCDEF01234567\",
     \"entries\": [$(entry alpha 1.0-3 1.0-2 published 2097152 1048576), $(entry beta 1.0-1 1.0-1 skipped 1024)]},
    {\"mirror\": \"edge\", \"arch\": \"aarch64\", \"status\": \"published\", \"entries\": [$(entry alpha 1.0-3 1.0-2 published 2097152 1048576)]}]" \
  "$plan"
report --outcome success || fail "render a publish"
head -1 "$T/out" | grep -qx '### Published to edge' && pass "the heading names the channel written" || fail "heading"
row beta | grep -q '| 1.0-1 already | 1.0-1 | – · next: promotion |' \
  && pass "a file the slot skipped reads as already served, not published" || fail "skipped file reported as published"
row alpha | grep -q '| x86_64, aarch64 | 1.0-2 | 1.0-3 | 2 MB (+1 MB) | \*\*1.0-3\*\* |' \
  && pass "an arch=any package is one row, with what it replaced and its size" || fail "alpha row"
row alpha | grep -q '| 1.0-1 · Mac set holds 1.0-1 |' && pass "a channel the run did not write says what holds it" || fail "Mac set hold"
grep -q 'Built from the PR.s build artifact.' "$T/out" && grep -q 'Signed with `89ABCDEF01234567`' "$T/out" \
  && pass "the source and the signing key are named once" || fail "source and signer"

# "Live" only when bin/check-served found every written slot served.
jq '.slots |= map(. + {served: {ok: true, checked_at: "2026-11-12T09:24:20Z", tries: 1, missing: []}})' "$T/record.json" > "$T/live.json"
mv "$T/live.json" "$T/record.json"
report --outcome success && head -1 "$T/out" | grep -qx '### Live on edge' \
  && pass "a publish every channel serves reads as live" || fail "live heading"
jq '.slots[1].served = {ok: false, checked_at: "2026-11-12T09:24:40Z", tries: 3, missing: ["alpha-1.0-3"]}' "$T/record.json" > "$T/live.json"
mv "$T/live.json" "$T/record.json"
report --outcome failure && head -1 "$T/out" | grep -qx '### Published to edge, but not served' \
  && grep -q '`edge/aarch64` does not list alpha-1.0-3 after 3 reads' "$T/out" \
  && pass "a publish the channel does not list yet says so, not live and not a failed build" || fail "unserved heading"

# The record says whether the Mac installer was told.
jq '.mac_installer = {status: "failed", detail: "HTTP 401", packages: [{name: "alpha", version: "1.0-3"}]}' \
  "$T/record.json" > "$T/live.json"
mv "$T/live.json" "$T/record.json"
report --outcome failure && grep -q '^\*\*omarchy-mac-installer was not told\*\* (HTTP 401)' "$T/out" \
  && pass "a failed Mac installer dispatch is named" || fail "Mac installer line"

# Without the Mac set, a normal-ring package waits for the next promotion.
: > "$T/inventory"
report --outcome success && row alpha | grep -q '| 1.0-1 · next: promotion | 1.0-1 · next: promotion |' \
  && pass "a normal-ring package waits for the next promotion" || fail "next promotion"

# Everything already published: say so for edge, not "everywhere".
record '[{"package": "alpha", "arch": "x86_64", "source": "already-published"}]' '[]' "$plan"
report --outcome success && head -1 "$T/out" | grep -qx '### Nothing to publish' \
  && grep -q "Edge already serves master's version of alpha (x86_64)" "$T/out" && ! grep -q everywhere "$T/out" \
  && pass "a run with nothing new names edge, the only channel it checked" || fail "already published"

# An artifact that could not be fetched is not a failed build.
record '[{"package": "alpha", "arch": "x86_64", "source": "artifact-download-failed"}]' '[]' "$plan"
report --outcome failure && grep -q 'could not be downloaded or unpacked' "$T/out" && ! grep -q 'has no build' "$T/out" \
  && pass "a download failure reads as one, not as a failed build" || fail "download failure"

# A Mac-set refusal stops every slot, edge included.
record '[{"package": "alpha", "arch": "x86_64", "source": "pr-artifact"}]' \
  '[{"mirror": "rc", "arch": "aarch64", "status": "refused", "packages": ["alpha-1.0-3-any"],
     "mac_set": [{"channel": "rc", "arch": "aarch64", "problems": [{"package": "alpha", "problem": "inventory lists 1.0-1"}]}]},
    {"mirror": "edge", "arch": "aarch64", "status": "not-run", "packages": ["alpha-1.0-3-any"]}]' "$plan"
report --outcome failure && head -1 "$T/out" | grep -qx '### Publish FAILED' \
  && grep -q 'refused `rc/aarch64`, so no channel was written, edge included. alpha: inventory lists 1.0-1.' "$T/out" \
  && row alpha | grep -q '| not run | \*\*refused\*\* |' \
  && pass "a Mac-set refusal says edge did not run either, and why" || fail "Mac set refusal"

# A catch-up refusal comes after the merge published: say what was written.
record '[{"package": "alpha", "arch": "x86_64", "source": "pr-artifact"}]' \
  "[{\"mirror\": \"edge\", \"arch\": \"aarch64\", \"status\": \"published\", \"entries\": [$(entry alpha 1.0-3 1.0-2 published)]},
    {\"mirror\": \"rc\", \"arch\": \"aarch64\", \"status\": \"refused\", \"packages\": []}]" "$plan"
report --outcome failure && grep -q 'refused `rc/aarch64`, so the fast-ring catch-up into it did not run. The channels above it are written.' "$T/out" \
  && ! grep -q 'edge included' "$T/out" \
  && pass "a catch-up refusal after a publish does not claim nothing was written" || fail "catch-up refusal"

# The catch-up later in the run replaced rc's alpha: show what rc serves now.
record '[{"package": "alpha", "arch": "x86_64", "source": "pr-artifact"}]' \
  "[{\"mirror\": \"rc\", \"arch\": \"aarch64\", \"status\": \"published\", \"entries\": [$(entry alpha 1.0-2 1.0-1 published)]},
    {\"mirror\": \"rc\", \"arch\": \"aarch64\", \"status\": \"published\", \"entries\": [$(entry alpha 1.0-3 1.0-2 published)]}]" "$plan"
report --outcome success && row alpha | grep -q '| \*\*1.0-3\*\* |' && ! row alpha | grep -q '\*\*1.0-2\*\*' \
  && pass "a channel two slots wrote shows the last write" || fail "last write"

# A slot handed two copies of alpha published the newer and skipped the older.
record '[{"package": "alpha", "arch": "x86_64", "source": "pr-artifact"}]' \
  "[{\"mirror\": \"edge\", \"arch\": \"aarch64\", \"status\": \"published\",
     \"entries\": [$(entry alpha 1.0-3 1.0-2 published), $(entry alpha 1.0-1 1.0-2 skipped)]}]" "$plan"
report --outcome success && row alpha | grep -q '| 1.0-2 | 1.0-3 |  | \*\*1.0-3\*\* |' \
  && pass "a published package beats a skipped copy of it in the same slot" || fail "published beats skipped"

# A failed slot: the ones before it landed, the ones after did not run.
record '[{"package": "alpha", "arch": "x86_64", "source": "pr-artifact"}]' \
  "[{\"mirror\": \"edge\", \"arch\": \"x86_64\", \"status\": \"published\", \"entries\": [$(entry alpha 1.0-3 1.0-2 published)]},
    {\"mirror\": \"edge\", \"arch\": \"aarch64\", \"status\": \"failed\", \"packages\": [\"alpha-1.0-3-any\"]},
    {\"mirror\": \"rc\", \"arch\": \"x86_64\", \"status\": \"not-run\", \"packages\": [\"alpha-1.0-3-any\"]}]" "$plan"
report --outcome failure && grep -q 'Writing `edge/aarch64` failed; `rc/x86_64` did not run.' "$T/out" \
  && pass "a failed slot names the slots that did not run" || fail "failed slot"

# No record at all: still a report, pointing at the run.
rm "$T/record.json"
"$ROOT/bin/publish-report" --outcome failure --run https://example.invalid/run --commit cad67735 > "$T/out" 2>&1 \
  && grep -q 'before it wrote a record' "$T/out" && grep -q '\[run\](https://example.invalid/run)' "$T/out" \
  && pass "a publish that wrote no record still gets a report" || fail "missing record"
