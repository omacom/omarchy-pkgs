#!/bin/bash
# Published 1password packages are built on a build host, so polkit owners
# must come from the installing machine, as users: polkit ignores groups here.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PKG="$ROOT/pkgbuilds/1password"
TPL="$ROOT/tests/fixtures/1password/com.1password.1Password.policy.tpl"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if grep -n '/etc/passwd' "$PKG/PKGBUILD"; then
  fail "PKGBUILD reads the build host's passwd"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The stub the package ships: the template rendered by package()'s own sed line.
sed_line=$(grep -o "sed 's/\\\\\${POLICY_OWNERS}/[^']*/g'" "$PKG/PKGBUILD") || fail "package() does not render the template"
eval "$sed_line" "$TPL" > "$tmp/policy"
if grep -q '\${' "$tmp/policy"; then fail "shipped policy keeps a placeholder"; fi
[[ $(grep -c 'policykit.owner">unix-user:root<' "$tmp/policy") == 2 ]] || fail "shipped policy is not the root stub"

cat > "$tmp/passwd" <<'PASSWD'
root:x:0:0::/root:/bin/bash
builder:x:999:999::/home/builder:/bin/bash
alice:x:1000:1000::/home/alice:/bin/bash
bob:x:1001:1001::/home/bob:/bin/zsh
nobody:x:65534:65534::/:/usr/bin/nologin
PASSWD

# shellcheck disable=SC1091
source "$PKG/1password.install"
set_policy_owners "$tmp/policy" "$tmp/passwd"
[[ $(grep -c 'policykit.owner">unix-user:alice unix-user:bob<' "$tmp/policy") == 2 ]] ||
  fail "installed policy does not name the machine's users: $(grep owner "$tmp/policy")"

# An upgrade rewrites rather than appends.
set_policy_owners "$tmp/policy" "$tmp/passwd"
[[ $(grep -c 'policykit.owner">unix-user:alice unix-user:bob<' "$tmp/policy") == 2 ]] || fail "upgrade does not rewrite the owners"

grep -q 'set_policy_owners' <(declare -f post_install) || fail "post_install does not set owners"
grep -q 'set_policy_owners' <(declare -f post_upgrade) || fail "post_upgrade does not set owners"

printf 'PASS: 1password polkit owners are the installing machine users\n'
