#!/bin/bash
# Self-test for bin/mac-installer-dispatch: what it sends to
# omarchy-mac-installer after a publish, and when it sends nothing. curl is a
# stub on PATH, so nothing leaves the machine.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
# The stub serves the edge database for a GET and answers a POST with
# $STUB_STATUS, keeping the request (arguments, stdin, body) for the checks.
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
if [[ " $* " == *" -X POST "* ]]; then
  printf '%s\n' "$@" > "$STUB_DIR/post-args"
  cat > "$STUB_DIR/post-stdin"
  while [[ $# -gt 0 ]]; do [[ $1 == --data ]] && printf '%s' "$2" > "$STUB_DIR/post-body"; shift; done
  [[ ${STUB_STATUS:-204} == fail ]] && exit 7
  printf '%s' "${STUB_STATUS:-204}"
else
  [[ ${STUB_DB:-ok} == fail ]] && exit 22
  printf '%s\n' "$@" > "$STUB_DIR/get-args"
  printf 'edge database bytes'
fi
STUB
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH" STUB_DIR=$T
export GITHUB_REPOSITORY=omacom/omarchy-pkgs GITHUB_SHA=abc123 GITHUB_RUN_ID=42 GITHUB_SERVER_URL=https://github.com
DB_SHA=$(printf 'edge database bytes' | sha256sum | cut -d' ' -f1)

record() { # target, then slot JSON objects
  local target=$1; shift
  jq -n --arg target "$target" --argjson slots "$(printf '%s\n' "$@" | jq -sc .)" \
    '{target: $target, sources: [], slots: $slots}' > "$T/record.json"
}
slot() { # mirror arch status files...
  local mirror=$1 arch=$2 status=$3; shift 3
  jq -nc --arg m "$mirror" --arg a "$arch" --arg s "$status" '{mirror:$m, arch:$a, status:$s, packages:$ARGS.positional}' --args "$@"
}
run() { rm -f "$T"/post-*; "$ROOT/bin/mac-installer-dispatch" "$@" "$T/record.json"; }

# --- what is sent -----------------------------------------------------------
record live \
  "$(slot edge x86_64 published linux-aurora-7.1.12.aurora2-12-x86_64 omarchy-settings-dev-4.0.0.r6975.g2b8177f-1-any)" \
  "$(slot edge aarch64 published linux-aurora-7.1.12.aurora2-12-aarch64 linux-aurora-debug-7.1.12.aurora2-12-aarch64 \
      omarchy-settings-dev-4.0.0.r6975.g2b8177f-1-any asdcontrol-1:0.6.0-2-aarch64)" \
  "$(slot rc aarch64 published walker-2.17.2-1-aarch64)"
out=$(run --dry-run)
[[ $(jq -c .packages <<<"$out") == '[{"name":"asdcontrol","version":"1:0.6.0-2"},{"name":"linux-aurora","version":"7.1.12.aurora2-12"},{"name":"omarchy-settings-dev","version":"4.0.0.r6975.g2b8177f-1"}]' ]] \
  && pass "only edge/aarch64 packages are sent, by name and version, debug packages left out" || fail "packages: $out"
[[ $(jq -r '[.schema, .channel, .arch] | map(tostring) | join(" ")' <<<"$out") == "1 edge aarch64" ]] \
  && pass "the payload names its schema, channel and architecture" || fail "header: $out"
[[ $(jq -r .database_sha256 <<<"$out") == "$DB_SHA" ]] \
  && pass "the edge database's sha256 is included" || fail "database: $out"
[[ $(jq -c .source <<<"$out") == '{"repository":"omacom/omarchy-pkgs","commit":"abc123","run":"https://github.com/omacom/omarchy-pkgs/actions/runs/42"}' ]] \
  && pass "the payload names the commit and run that published" || fail "source: $out"
[[ ! -e $T/post-args ]] && pass "a dry run sends nothing" || fail "dry run posted"
grep -qE '^https://pkgs\.omarchy\.org/edge/aarch64/omarchy\.db\?[0-9]+$' "$T/get-args" && grep -qx 'Cache-Control: no-cache' "$T/get-args" \
  && pass "the database is read past the CDN's cache" || fail "database url: $(cat "$T/get-args")"

out=$(STUB_DB=fail run --dry-run)
[[ $(jq 'has("database_sha256")' <<<"$out") == false ]] \
  && pass "an unreadable database is left out, not guessed" || fail "database on failure: $out"

# --- sending ----------------------------------------------------------------
out=$(MAC_INSTALLER_DISPATCH_TOKEN=secret-token run)
[[ $out == *"Notified omacom/omarchy-mac-installer"* ]] && pass "a 204 is reported as sent" || fail "send: $out"
grep -qx 'https://api.github.com/repos/omacom/omarchy-mac-installer/dispatches' "$T/post-args" \
  && pass "it posts to omarchy-mac-installer's dispatches endpoint" || fail "url: $(cat "$T/post-args")"
[[ $(jq -r .event_type "$T/post-body") == edge-mac-changed && $(jq -r '.client_payload.packages | length' "$T/post-body") == 3 ]] \
  && [[ $(jq -r '.client_payload.database_sha256' "$T/post-body") == "$DB_SHA" ]] \
  && [[ $(jq -r '[.client_payload.packages[].name] | join(" ")' "$T/post-body") == "asdcontrol linux-aurora omarchy-settings-dev" ]] \
  && pass "the event is edge-mac-changed with the payload" || fail "body: $(cat "$T/post-body")"
! grep -q secret-token "$T/post-args" && grep -q 'Bearer secret-token' "$T/post-stdin" \
  && pass "the token reaches curl on stdin, never its arguments" || fail "token handling"

out=$(MAC_INSTALLER_DISPATCH_TOKEN=secret-token STUB_STATUS=401 run) \
  && [[ $out == *"::warning"*"HTTP 401"* ]] && pass "a refused dispatch warns and exits 0" || fail "401: $out"
out=$(MAC_INSTALLER_DISPATCH_TOKEN=secret-token STUB_STATUS=fail run) \
  && [[ $out == *"::warning"*"HTTP 000"* ]] && pass "an unreachable API warns and exits 0" || fail "network: $out"

# --- when nothing is sent ---------------------------------------------------
out=$(MAC_INSTALLER_DISPATCH_TOKEN= run) && [[ $out == *"::notice"*"not set"* && ! -e $T/post-args ]] \
  && pass "without the token it skips with a notice and exits 0" || fail "no token: $out"

record live "$(slot edge x86_64 published linux-aurora-7.1.12.aurora2-12-x86_64)" "$(slot stable aarch64 published walker-2.17.2-1-aarch64)"
out=$(MAC_INSTALLER_DISPATCH_TOKEN=secret-token run) && [[ $out == *"nothing was published into edge/aarch64"* && ! -e $T/post-args ]] \
  && pass "an x86_64-only (or non-edge) publish sends nothing" || fail "x86_64 only: $out"

record live "$(slot edge aarch64 published linux-aurora-7.1.12.aurora2-12-aarch64)" "$(slot rc x86_64 failed walker-2.17.2-1-x86_64)"
out=$(MAC_INSTALLER_DISPATCH_TOKEN=secret-token run) && [[ $(jq -r '[.client_payload.packages[].name] | join(" ")' "$T/post-body") == linux-aurora ]] \
  && pass "a later failed slot does not hold back a published edge/aarch64 slot" || fail "later failure: $out"

record live "$(slot edge aarch64 failed linux-aurora-7.1.12.aurora2-12-aarch64)"
out=$(MAC_INSTALLER_DISPATCH_TOKEN=secret-token run) && [[ ! -e $T/post-args ]] \
  && pass "a failed edge/aarch64 slot sends nothing" || fail "failed slot: $out"

record live "$(slot edge aarch64 published linux-aurora-debug-7.1.12.aurora2-12-aarch64)"
out=$(MAC_INSTALLER_DISPATCH_TOKEN=secret-token run) && [[ ! -e $T/post-args ]] \
  && pass "a debug-only publish sends nothing" || fail "debug only: $out"

record scratch/proof "$(slot edge aarch64 published linux-aurora-7.1.12.aurora2-12-aarch64)"
out=$(MAC_INSTALLER_DISPATCH_TOKEN=secret-token run) && [[ $out == *"not the live channels"* && ! -e $T/post-args ]] \
  && pass "a proof run into a scratch prefix sends nothing" || fail "prefix: $out"

echo '{"slots": "nope"}' > "$T/record.json"
out=$(MAC_INSTALLER_DISPATCH_TOKEN=secret-token "$ROOT/bin/mac-installer-dispatch" "$T/record.json") && [[ $out == *"::warning"* ]] \
  && pass "a malformed record warns and exits 0" || fail "malformed: $out"

# release-rc.yml's record: the omarchy pair carried from rc into edge.
jq -n '{kind: "release-rc", target: "live", result: "success", sources: [], slots: [
  {mirror: "rc", arch: "aarch64", status: "published", packages: ["omarchy-4.1.0-1-any", "omarchy-settings-4.1.0-1-any"]},
  {mirror: "edge", arch: "aarch64", status: "published", packages: ["omarchy-4.1.0-1-any", "omarchy-settings-4.1.0-1-any"]}]}' > "$T/record.json"
out=$(run --dry-run)
[[ $(jq -c .packages <<<"$out") == '[{"name":"omarchy","version":"4.1.0-1"},{"name":"omarchy-settings","version":"4.1.0-1"}]' ]] \
  && pass "a release candidate's carry into edge sends the omarchy pair" || fail "release-rc: $out"
