#!/bin/bash
#
# antigravity.install applies the deb postinst's chrome-sandbox mode.
# package() always ships 0755; this hook is what changes it on the machine.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$fixture/bin" "$fixture/ns"
ln -s . "$fixture/ns/user"
cat >"$fixture/bin/unshare" <<'EOF'
#!/bin/bash
[[ ${ANTIGRAVITY_TEST_USERNS:-0} == 1 ]]
EOF
cat >"$fixture/bin/setpriv" <<'EOF'
#!/bin/bash
while [[ $# -gt 0 ]]; do
  if [[ $1 == -- ]]; then
    shift
    break
  fi
  shift
done
"$@"
EOF
chmod +x "$fixture/bin/unshare" "$fixture/bin/setpriv"

export PATH="$fixture/bin:$PATH"
export ANTIGRAVITY_USERNS_LINK="$fixture/ns/user"
export ANTIGRAVITY_SANDBOX="$fixture/chrome-sandbox"
# shellcheck disable=SC1091
source "$ROOT/pkgbuilds/antigravity/antigravity.install"

mode() {
  python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o7777, "o"))' "$ANTIGRAVITY_SANDBOX"
}

: >"$ANTIGRAVITY_SANDBOX"
chmod 0644 "$ANTIGRAVITY_SANDBOX"
ANTIGRAVITY_TEST_USERNS=1 post_install
[[ $(mode) == 755 ]] || fail "user namespaces left chrome-sandbox as $(mode)"

chmod 0755 "$ANTIGRAVITY_SANDBOX"
ANTIGRAVITY_TEST_USERNS=0 post_upgrade
[[ $(mode) == 4755 ]] || fail "no user namespaces left chrome-sandbox as $(mode)"

rm "$ANTIGRAVITY_SANDBOX"
post_install || fail "a missing sandbox failed the install hook"

# The recipe's own depends cover what the deb lists and ldd does not show.
recipe=$(cat "$ROOT/pkgbuilds/antigravity/PKGBUILD")
for dep in libxss libxtst util-linux hicolor-icon-theme; do
  grep -Fq "'$dep'" <<<"$recipe" || fail "PKGBUILD does not depend on $dep"
done
grep -Fq 'chmod 0755 opt/Antigravity/chrome-sandbox' <<<"$recipe" \
  || fail "package() does not clear the setuid bit"
grep -Fq 'install=antigravity.install' <<<"$recipe" \
  || fail "the sandbox hook is not the package install script"

echo "antigravity install hook checks passed"
