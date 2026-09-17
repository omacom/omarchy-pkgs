#!/bin/bash
# 1password must render polkit owners from the target machine, not the builder.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PKG="$ROOT/pkgbuilds/1password"
INSTALL="$PKG/1password.install"
PKGBUILD="$PKG/PKGBUILD"
TPL="$ROOT/tests/fixtures/1password/com.1password.1Password.policy.tpl"
PASSWD="$ROOT/tests/fixtures/1password/passwd"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if grep -n '/etc/passwd' "$PKGBUILD"; then
  fail "PKGBUILD still reads /etc/passwd at package time"
fi
if grep -E 'rm .*policy\.tpl' "$PKGBUILD"; then
  fail "PKGBUILD still deletes the vendor policy template"
fi

# shellcheck source=/dev/null
source "$INSTALL"
declare -F render_1password_polkit_policy >/dev/null || fail "render_1password_polkit_policy is not defined"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
render_1password_polkit_policy "$TPL" "$tmp" "$PASSWD"

grep -q 'unix-user:alice' "$tmp" || fail "rendered policy missing target user alice"
grep -q 'unix-user:bob' "$tmp" || fail "rendered policy missing target user bob"
grep -q 'unix-user:builder' "$tmp" && fail "rendered policy still names builder"
grep -q 'unix-user:root' "$tmp" && fail "rendered policy included a system account"

printf 'PASS: 1password polkit owners come from the target passwd\n'
