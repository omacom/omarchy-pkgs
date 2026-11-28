#!/bin/bash
# Self-test for bin/append-publish-log and workflow publish-log safety.
set -euo pipefail

ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; [[ -s "$T/out" ]] && cat "$T/out" >&2; exit 1; }

SCRIPT="$ROOT/bin/append-publish-log"
if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT does not exist or is not executable" >&2
  exit 1
fi

# --- Real rclone tests against a local directory as the remote ---
REMOTE="$T/r2"
mkdir -p "$REMOTE"

cat > "$T/rec1.json" <<'JSON'
{
  "time": "2026-11-28T00:00:01Z",
  "commit": "aaaaaaa",
  "slots": [{"mirror": "edge", "arch": "x86_64", "status": "published"}]
}
JSON

cat > "$T/rec2.json" <<'JSON'
{"time":"2026-11-28T00:00:02Z","kind":"promote","slots":[]}
JSON

cat > "$T/rec3.json" <<'JSON'
{"time":"2026-11-28T00:00:03Z","kind":"release-rc","slots":[]}
JSON

# 1. Brand-new log when remote has no publish-log.jsonl
"$SCRIPT" --remote "$REMOTE" "$T/rec1.json" >"$T/out" 2>&1 \
  || fail "brand-new log should succeed"
[[ -f "$REMOTE/publish-log.jsonl" ]] || fail "publish-log.jsonl was not created"
[[ $(wc -l < "$REMOTE/publish-log.jsonl") -eq 1 ]] || fail "expected 1 line after first append"
grep -q "log now has 1 entries" "$T/out" || fail "expected entry count message"
[[ $(jq -r .commit "$REMOTE/publish-log.jsonl") == "aaaaaaa" ]] || fail "first entry content mismatch"
pass "brand-new publish-log.jsonl is created when rclone lsf returns empty"

# 2. Existing log appends without truncating previous entries
"$SCRIPT" --remote "$REMOTE" "$T/rec2.json" >"$T/out" 2>&1 \
  || fail "second append should succeed"
[[ $(wc -l < "$REMOTE/publish-log.jsonl") -eq 2 ]] || fail "expected 2 lines after second append"
grep -q "log now has 2 entries" "$T/out" || fail "expected 2 entries message"
[[ $(sed -n 1p "$REMOTE/publish-log.jsonl" | jq -r .commit) == "aaaaaaa" ]] || fail "first entry lost"
[[ $(sed -n 2p "$REMOTE/publish-log.jsonl" | jq -r .kind) == "promote" ]] || fail "second entry mismatch"
pass "existing publish-log.jsonl appends cleanly without truncation"

# 3. Reading record from stdin (-)
cat "$T/rec3.json" | "$SCRIPT" --remote "$REMOTE" - >"$T/out" 2>&1 \
  || fail "stdin append should succeed"
[[ $(wc -l < "$REMOTE/publish-log.jsonl") -eq 3 ]] || fail "expected 3 lines after stdin append"
[[ $(sed -n 3p "$REMOTE/publish-log.jsonl" | jq -r .kind) == "release-rc" ]] || fail "stdin entry mismatch"
pass "record can be piped on stdin with -"

# 4. Existing remote log without trailing newline does not glue JSON lines together
printf '{"time":"2026-11-28T00:00:00Z","existing":true}' > "$REMOTE/no-newline.jsonl"
"$SCRIPT" --remote "$REMOTE" --object no-newline.jsonl "$T/rec2.json" >"$T/out" 2>&1 \
  || fail "append to file without trailing newline should succeed"
[[ $(wc -l < "$REMOTE/no-newline.jsonl") -eq 2 ]] || fail "expected 2 lines after missing-newline append"
jq -e . "$REMOTE/no-newline.jsonl" >/dev/null || fail "resulting jsonl is invalid"
pass "existing log without trailing newline gets separated cleanly"

# 5. Subdirectories in the remote do not confuse --max-depth 1 existence check
mkdir -p "$REMOTE/edge/x86_64"
printf '{"nested":true}\n' > "$REMOTE/edge/x86_64/nested.jsonl"
"$SCRIPT" --remote "$REMOTE" --object nested.jsonl "$T/rec2.json" >"$T/out" 2>&1 \
  || fail "nested same-name object should not break top-level check"
[[ $(wc -l < "$REMOTE/nested.jsonl") -eq 1 ]] || fail "expected 1 line in top-level nested.jsonl"
pass "same-name object in subdirectory does not interfere with root object"

# 6. Invalid / non-object / multi-object JSON fails closed before touching remote
before_hash=$(sha256sum "$REMOTE/publish-log.jsonl")
printf 'not json\n' > "$T/bad.json"
! "$SCRIPT" --remote "$REMOTE" "$T/bad.json" >"$T/out" 2>&1 \
  || fail "invalid JSON should fail"
printf '[1,2,3]\n' > "$T/arr.json"
! "$SCRIPT" --remote "$REMOTE" "$T/arr.json" >"$T/out" 2>&1 \
  || fail "JSON array should fail"
printf '{"a":1}\n{"b":2}\n' > "$T/two.json"
! "$SCRIPT" --remote "$REMOTE" "$T/two.json" >"$T/out" 2>&1 \
  || fail "multiple JSON objects should fail"
[[ $(sha256sum "$REMOTE/publish-log.jsonl") == "$before_hash" ]] || fail "remote modified on invalid input"
pass "invalid, non-object, and multi-object JSON fail closed without touching remote"

# --- Stub rclone tests for transient R2 failure modes ---
STUB="$T/stub-rclone"
STUB_LOG="$T/stub-calls.log"
cat > "$STUB" <<'STUBEOF'
#!/bin/bash
set -euo pipefail
echo "$*" >> "$STUB_LOG"
cmd=$1; shift
case "$cmd" in
  lsf)
    case "${STUB_LSF_MODE:-exists}" in
      fail)
        echo "ERROR : simulated 503 Service Unavailable" >&2
        exit 1
        ;;
      empty)
        exit 0
        ;;
      exists)
        printf "%s;publish-log.jsonl\n" "${STUB_REMOTE_SIZE:-42}"
        exit 0
        ;;
    esac
    ;;
  copyto)
    src=$1; dst=$2
    if [[ "$src" == R2:* ]]; then
      case "${STUB_DOWNLOAD_MODE:-ok}" in
        fail)
          echo "ERROR : simulated transient download timeout" >&2
          exit 1
          ;;
        empty_file)
          : > "$dst"
          exit 0
          ;;
        no_file)
          exit 0
          ;;
        truncated)
          printf '{"a":1}\n' > "$dst"
          exit 0
          ;;
        ok)
          printf '%s' "${STUB_REMOTE_CONTENT:-}" > "$dst"
          exit 0
          ;;
      esac
    else
      if [[ "${STUB_UPLOAD_MODE:-ok}" == "fail" ]]; then
        echo "ERROR : simulated upload failure" >&2
        exit 1
      fi
      cp "$src" "$STUB_UPLOADED"
      exit 0
    fi
    ;;
  *)
    echo "unexpected rclone subcommand: $cmd" >&2
    exit 99
    ;;
esac
STUBEOF
chmod +x "$STUB"

# 7. Transient rclone lsf error fails closed without uploading
: > "$STUB_LOG"
rm -f "$T/uploaded"
if STUB_LOG="$STUB_LOG" STUB_UPLOADED="$T/uploaded" STUB_LSF_MODE=fail \
  "$SCRIPT" --rclone "$STUB" --remote R2:omarchy-pkgs "$T/rec1.json" >"$T/out" 2>&1; then
  fail "rclone lsf failure must fail closed"
fi
[[ ! -e "$T/uploaded" ]] || fail "lsf failure must never upload"
! grep -q "^copyto " "$STUB_LOG" || fail "lsf failure must never invoke copyto"
pass "transient rclone lsf error fails closed without overwriting remote"

# 8. Transient rclone copyto download error when object exists fails closed without uploading
: > "$STUB_LOG"
rm -f "$T/uploaded"
if STUB_LOG="$STUB_LOG" STUB_UPLOADED="$T/uploaded" STUB_LSF_MODE=exists STUB_DOWNLOAD_MODE=fail \
  "$SCRIPT" --rclone "$STUB" --remote R2:omarchy-pkgs "$T/rec1.json" >"$T/out" 2>&1; then
  fail "rclone copyto download failure must fail closed"
fi
[[ ! -e "$T/uploaded" ]] || fail "download failure must never upload"
pass "transient rclone copyto download error fails closed without overwriting remote"

# 9. Truncated download (byte size mismatch against lsf size) fails closed without uploading
: > "$STUB_LOG"
rm -f "$T/uploaded"
if STUB_LOG="$STUB_LOG" STUB_UPLOADED="$T/uploaded" STUB_LSF_MODE=exists STUB_REMOTE_SIZE=500 STUB_DOWNLOAD_MODE=truncated \
  "$SCRIPT" --rclone "$STUB" --remote R2:omarchy-pkgs "$T/rec1.json" >"$T/out" 2>&1; then
  fail "truncated download must fail closed"
fi
[[ ! -e "$T/uploaded" ]] || fail "truncated download must never upload"
pass "truncated download (size mismatch) fails closed without overwriting remote"

# 10. Upload failure propagates non-zero exit (and actually reached upload)
: > "$STUB_LOG"
rm -f "$T/uploaded"
remote_body=$'{"prev":1}\n'
remote_size=${#remote_body}
if STUB_LOG="$STUB_LOG" STUB_UPLOADED="$T/uploaded" STUB_LSF_MODE=exists \
  STUB_REMOTE_SIZE="$remote_size" STUB_REMOTE_CONTENT="$remote_body" STUB_UPLOAD_MODE=fail \
  "$SCRIPT" --rclone "$STUB" --remote R2:omarchy-pkgs "$T/rec1.json" >"$T/out" 2>&1; then
  fail "upload failure must propagate non-zero exit"
fi
[[ $(grep -c "^copyto " "$STUB_LOG") -eq 2 ]] || fail "expected download + upload copyto calls before failure"
grep -q "^copyto .* R2:omarchy-pkgs/publish-log.jsonl " "$STUB_LOG" || fail "upload copyto call was never attempted"
pass "upload failure exits non-zero after attempting upload"

# 10a. Successful download command that produces no local file fails closed
: > "$STUB_LOG"
rm -f "$T/uploaded"
if STUB_LOG="$STUB_LOG" STUB_UPLOADED="$T/uploaded" STUB_LSF_MODE=exists STUB_DOWNLOAD_MODE=no_file \
  "$SCRIPT" --rclone "$STUB" --remote R2:omarchy-pkgs "$T/rec1.json" >"$T/out" 2>&1; then
  fail "missing downloaded file must fail closed"
fi
[[ ! -e "$T/uploaded" ]] || fail "missing downloaded file must never upload"
[[ $(grep -c "^copyto " "$STUB_LOG") -eq 1 ]] || fail "must not attempt upload after missing download file"
pass "download exiting 0 without creating local file fails closed"

# 10b. Empty lsf output skips download and uploads a brand-new 1-line log
: > "$STUB_LOG"
rm -f "$T/uploaded"
STUB_LOG="$STUB_LOG" STUB_UPLOADED="$T/uploaded" STUB_LSF_MODE=empty \
  "$SCRIPT" --rclone "$STUB" --remote R2:omarchy-pkgs "$T/rec1.json" >"$T/out" 2>&1 \
  || fail "empty lsf should create brand-new log"
[[ $(grep -c "^copyto " "$STUB_LOG") -eq 1 ]] || fail "empty lsf should only call copyto once (upload)"
[[ $(wc -l < "$T/uploaded") -eq 1 ]] || fail "expected 1 line in brand-new upload"
pass "empty lsf creates new 1-line log without attempting download"

# 10c. Invalid --object names fail closed
for bad_obj in "" "sub/publish-log.jsonl" "bad;name.jsonl" "has space.jsonl"; do
  ! "$SCRIPT" --remote "$REMOTE" --object "$bad_obj" "$T/rec1.json" >"$T/out" 2>&1 \
    || fail "invalid object name should be rejected: $bad_obj"
done
pass "invalid --object values are rejected"

# 11. Workflow invariants: no silent wipe fallback & all publish-log writers share serialized concurrency group
python3 - "$ROOT" <<'PYEOF'
import pathlib, sys, yaml

root = pathlib.Path(sys.argv[1])
workflows_dir = root / ".github" / "workflows"
writers = []

for wf_path in sorted(workflows_dir.glob("*.yml")):
    text = wf_path.read_text()
    if ": > publish-log.jsonl" in text or "|| : >" in text:
        sys.exit(f"FAIL: unsafe silent truncation fallback still present in {wf_path.name}")
    doc = yaml.safe_load(text)
    for job_id, job in (doc.get("jobs") or {}).items():
        steps = job.get("steps") or []
        uses_log = False
        has_checkout_before = False
        checked_out = False
        for step in steps:
            uses = step.get("uses") or ""
            if uses.startswith("actions/checkout@"):
                checked_out = True
            run = step.get("run") or ""
            if "append-publish-log" in run or "publish-log.jsonl" in run:
                uses_log = True
                if checked_out:
                    has_checkout_before = True
                if "bin/append-publish-log" not in run:
                    sys.exit(f"FAIL: {wf_path.name}:{job_id} touches publish-log.jsonl without bin/append-publish-log")
        if uses_log:
            if not has_checkout_before:
                sys.exit(f"FAIL: {wf_path.name}:{job_id} invokes bin/append-publish-log without prior actions/checkout")
            conc = job.get("concurrency") or {}
            if not isinstance(conc, dict):
                sys.exit(f"FAIL: {wf_path.name}:{job_id} must use mapping concurrency config")
            if conc.get("cancel-in-progress") is not False:
                sys.exit(f"FAIL: {wf_path.name}:{job_id} must set concurrency.cancel-in-progress: false")
            if conc.get("queue") != "max":
                sys.exit(f"FAIL: {wf_path.name}:{job_id} must set concurrency.queue: max")
            writers.append((wf_path.name, job_id, conc.get("group")))

expected = {("publish.yml", "publish"), ("promote.yml", "promote"), ("release-rc.yml", "publish")}
found = {(wf, job) for wf, job, _ in writers}
if found != expected:
    sys.exit(f"FAIL: expected publish-log writers {sorted(expected)}, found {sorted(found)}")
groups = {grp for _, _, grp in writers}
if len(groups) != 1 or not next(iter(groups)):
    sys.exit(f"FAIL: all publish-log writers must share one non-empty concurrency group, got {writers}")
shared_group = next(iter(groups))

# Every job sharing the publish concurrency group across all workflows must keep
# cancel-in-progress: false and queue: max, and publish.yml:report must stay outside it.
for wf_path in sorted(workflows_dir.glob("*.yml")):
    doc = yaml.safe_load(wf_path.read_text())
    for job_id, job in (doc.get("jobs") or {}).items():
        conc = job.get("concurrency")
        if isinstance(conc, dict) and conc.get("group") == shared_group:
            if conc.get("cancel-in-progress") is not False or conc.get("queue") != "max":
                sys.exit(f"FAIL: {wf_path.name}:{job_id} in group {shared_group!r} must set cancel-in-progress: false and queue: max")
        if wf_path.name == "publish.yml" and job_id == "report" and conc:
            sys.exit("FAIL: publish.yml:report should not hold a concurrency lock")

rc_text = (workflows_dir / "release-rc.yml").read_text()
if "[[ $(jq " in rc_text:
    sys.exit("FAIL: release-rc.yml must not mask jq errors inside [[ ... ]] || exit 0")

print(f"PASS: all {len(writers)} workflow publish-log writers use bin/append-publish-log and share concurrency group {shared_group!r} with cancel-in-progress=false, queue=max")
PYEOF
