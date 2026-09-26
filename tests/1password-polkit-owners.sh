#!/bin/bash
# Binary 1password packages cannot bake the build host passwd into polkit owners.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PKG="$ROOT/pkgbuilds/1password"
INSTALL="$PKG/1password.install"
PKGBUILD="$PKG/PKGBUILD"
TPL="$ROOT/tests/fixtures/1password/com.1password.1Password.policy.tpl"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if grep -n '/etc/passwd' "$PKGBUILD"; then
  fail "PKGBUILD still reads /etc/passwd at package time"
fi
grep -q 'unix-group:wheel' "$PKGBUILD" || fail "PKGBUILD does not pin unix-group:wheel"
if grep -nE 'render_1password_polkit_policy|POLICY_TPL|POLICY_DEST' "$INSTALL"; then
  fail "install scriptlet still rewrites the polkit policy"
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
sed 's/\${POLICY_OWNERS}/unix-group:wheel/g' "$TPL" > "$tmp"
grep -q 'unix-group:wheel' "$tmp" || fail "substituted policy missing unix-group:wheel"
if grep -q 'unix-user:' "$tmp"; then
  fail "substituted policy still names a unix-user"
fi

printf 'PASS: 1password polkit owners are unix-group:wheel\n'
