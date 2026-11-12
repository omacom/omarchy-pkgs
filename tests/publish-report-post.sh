#!/bin/bash
# Self-test for bin/publish-report-post and bin/publish-report-refresh: one
# report per merge, edited in place by a rerun or a later promotion. gh is
# a stub on PATH that answers from files and logs every write, so nothing
# leaves the machine. Needs jq, curl and GNU tar with zstd.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; cat "$T/out" "$T/writes" 2>/dev/null; exit 1; }

mkdir "$T/bin" "$T/api"
# GET answers with $T/api/<path with / as _>, --jq applied; a write is
# logged as "<method> <path>".
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
[[ $1 == api ]] || exit 1; shift
method=GET jq_filter=. path=""
while [[ $# -gt 0 ]]; do
  case $1 in
  -X) method=$2; shift 2 ;;
  --jq) jq_filter=$2; shift 2 ;;
  -F|-f) shift 2 ;;
  --paginate) shift ;;
  *) path=$1; shift ;;
  esac
done
if [[ $method != GET ]]; then echo "$method $path" >> "$STUB_DIR/writes"; echo '{}'; exit 0; fi
file="$STUB_DIR/api/${path//\//_}"
[[ -f $file ]] || { echo "stub: no $path" >&2; exit 1; }
jq -r "$jq_filter" "$file"
STUB
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" STUB_DIR=$T
: > "$T/writes"

repo=omacom/omarchy-pkgs
api() { printf '%s' "$2" > "$T/api/${1//\//_}"; }
printf 'body\n' > "$T/body.md"
post() { "$ROOT/bin/publish-report-post" --repo "$repo" "$@" "$T/body.md" > "$T/out" 2>&1; }

api "repos/$repo/commits/aaa/pulls" '[{"number": 839, "merged_at": "2026-11-12T09:22:33Z"}]'
api "repos/$repo/issues/839/comments" '[{"id": 1, "user": {"login": "someone"}, "body": "<!-- publish-report aaa -->"},
  {"id": 2, "user": {"login": "github-actions[bot]"}, "body": "x\n<!-- publish-report aaa -->"},
  {"id": 3, "user": {"login": "github-actions[bot]"}, "body": "<!-- publish-report bbb -->"}]'
post --commit aaa && grep -qx "PATCH repos/$repo/issues/comments/2" "$T/writes" && (( $(wc -l < "$T/writes") == 1 )) \
  && pass "a rerun edits the bot's report for that commit, not a person's comment or another commit's" || fail "edit in place"

: > "$T/writes"
api "repos/$repo/commits/ccc/pulls" '[{"number": 840, "merged_at": "2026-11-12T10:00:00Z"}]'
api "repos/$repo/issues/840/comments" '[]'
post --commit ccc && grep -qx "POST repos/$repo/issues/840/comments" "$T/writes" \
  && pass "the first report is a new comment" || fail "new comment"
: > "$T/writes"
post --commit ccc --edit-only && [[ ! -s $T/writes ]] && grep -q 'nothing edited' "$T/out" \
  && pass "--edit-only never adds a comment" || fail "edit only"
api "repos/$repo/commits/ddd/pulls" '[]'
post --commit ddd && [[ ! -s $T/writes ]] && pass "a commit without a merged PR gets nothing" || fail "no PR"

# --- refresh after a promotion ----------------------------------------------
mkdir -p "$T/channels/rc/aarch64" "$T/db/alpha-1.0-3"
(cd "$T/db" && tar --zstd -cf "$T/channels/rc/aarch64/omarchy.db" -- *)
publish() { # publish <commit> <time> <file>
  jq -nc --arg c "$1" --arg t "$2" --arg f "$3" '{time: $t, commit: $c, run: "r", event: "push", target: "live", plan: [], sources: [],
    slots: [{mirror: "edge", arch: "aarch64", status: "published", packages: [$f]}]}'
}
{
  publish aaa 2026-11-10T00:00:00Z alpha-1.0-3-any
  publish ccc 2026-11-11T00:00:00Z beta-2.0-1-aarch64
  publish eee 2026-11-12T00:00:00Z gamma-1.0-1-aarch64
  # A rerun of aaa: the bucket already had the file, so its edge slot is unchanged.
  jq -nc '{time: "2026-11-12T00:30:00Z", commit: "aaa", run: "rerun", event: "push", target: "live", plan: [], sources: [],
    slots: [{mirror: "edge", arch: "aarch64", status: "unchanged", packages: []}]}'
  jq -nc '{kind: "promote", time: "2026-11-12T01:00:00Z", commit: "fff", event: "workflow_dispatch", target: "live", sources: [], slots: []}'
} > "$T/log.jsonl"
jq -n '{kind: "promote", slots: [{mirror: "rc", arch: "aarch64", status: "published", packages: ["alpha-1.0-3-any", "beta-2.0-1-aarch64"]},
                                 {mirror: "stable", arch: "aarch64", status: "failed", packages: ["gamma-1.0-1-aarch64"]}]}' > "$T/promote.json"
refresh() { "$ROOT/bin/publish-report-refresh" --repo "$repo" --channels "file://$T/channels" "$@" "$T/promote.json" "$T/log.jsonl" > "$T/out" 2>&1; }

refresh --dry-run && [[ $(grep -c 'would redraw' "$T/out") == 2 ]] \
  && grep -q 'would redraw the report for ccc ' "$T/out" && grep -q 'would redraw the report for aaa ' "$T/out" && ! grep -q eee "$T/out" \
  && pass "a promotion redraws the merges whose files it published, not the ones a failed slot held" || fail "refresh selection"
refresh --dry-run --max 1 && [[ $(grep -m1 'would redraw' "$T/out") == "would redraw the report for aaa from run rerun" ]] && grep -q 'not redrawn (over --max 1): ccc' "$T/out" \
  && pass "--max keeps the newest and lists the rest" || fail "refresh max"
: > "$T/writes"
refresh && grep -qx "PATCH repos/$repo/issues/comments/2" "$T/writes" && ! grep -q POST "$T/writes" \
  && pass "a refresh edits existing reports and adds none" || fail "refresh edit"
# aaa's newest record is the rerun, which ran after the attempt that wrote edge.
refresh --dry-run && grep -qx 'would redraw the report for aaa from run rerun' "$T/out" \
  && pass "a refresh draws a merge's newest record, a rerun included" || fail "refresh newest record"
