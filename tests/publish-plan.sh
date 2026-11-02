#!/bin/bash
# Self-test for bin/publish-plan: the matrix the publish job receives is
# turned into plan lines only when every field is one it may take.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

entry() { # entry <field=value...>: a valid entry with those fields replaced
  local e='{"package":"yaru-icon-theme","pkgbase":"yaru","arch":"x86_64","channels":"edge rc stable","publish_arches":"x86_64 aarch64","runner":"[]","decision":"reuse"}' kv
  for kv in "$@"; do e=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k] = $v' <<<"$e"); done
  echo "$e"
}
plan() { jq -c '{include: .}' <<<"[$(IFS=,; echo "$*")]" | "$ROOT/bin/publish-plan" 2>"$T/err"; }

[[ $(plan "$(entry)" "$(entry package=omarchy pkgbase=omarchy arch=aarch64 channels=edge publish_arches=aarch64 decision=published)") == \
  $'yaru-icon-theme x86_64 edge,rc,stable x86_64,aarch64 yaru reuse\nomarchy aarch64 edge aarch64 omarchy published' ]] \
  && pass "a valid matrix becomes one plan line per entry" || fail "valid matrix: $(cat "$T/err")"

[[ -z $(plan) ]] && pass "an empty matrix is an empty plan" || fail "empty matrix"

refused() { # refused <description> <entry json>
  if plan "$2" >/dev/null; then fail "$1 should be refused"; else pass "refused: $1"; fi
}
refused "a package name with shell characters" "$(entry 'package=a";b=1;$(true)||:;:"')"
refused "a pkgbase with quotes and a substitution" "$(entry "pkgbase=a'\$(true)'")"
refused "a name starting with a dash" "$(entry package=-rf)"
refused "a path as a name" "$(entry package=../helpers)"
refused "a channel list with more than words" "$(entry 'channels=stable;x')"
refused "a channel that does not exist" "$(entry 'channels=edge beta')"
refused "a channel named twice" "$(entry 'channels=edge edge')"
refused "an architecture that does not exist" "$(entry arch=riscv64)"
refused "a publish architecture that does not exist" "$(entry 'publish_arches=x86_64 any')"
refused "an unknown decision" "$(entry decision=skip)"
refused "a field with a newline" "$(entry $'pkgbase=yaru\nx')"
refused "a missing field" "$(jq -c 'del(.pkgbase)' <<<"$(entry)")"
refused "a non-string field" "$(jq -c '.arch = ["x86_64"]' <<<"$(entry)")"
if "$ROOT/bin/publish-plan" <<<'[]' >/dev/null 2>&1; then fail "a non-matrix should be refused"; else pass "refused: not a matrix"; fi
