#!/bin/bash
# Self-test for helpers/artifact-helpers.sh: package files survive the
# artifact hop between build-pr.yml and publish.yml with makepkg's names
# intact, including the colon an epoch puts in them.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
source "$ROOT/helpers/artifact-helpers.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

EPOCH='cursor-cli-1:2026.09.18.1.9a7762b-1-x86_64.pkg.tar.zst'
PLAIN='beta-1.0-1-x86_64.pkg.tar.zst'
mkdir -p "$T/built" "$T/artifact" "$T/out"
echo epoch > "$T/built/$EPOCH"
echo plain > "$T/built/$PLAIN"
echo sig > "$T/built/$PLAIN.sig"
echo db > "$T/built/omarchy.db.tar.zst"

pack_packages "$T/built" "$T/artifact/packages.tar" || fail "pack"
[[ "$(tar -tf "$T/artifact/packages.tar" | sort | tr '\n' ' ')" == "$PLAIN $EPOCH " ]] \
  && pass "packages.tar holds the packages only, no signature or database" || fail "tar contents: $(tar -tf "$T/artifact/packages.tar" | tr '\n' ' ')"
[[ "$(ls "$T/artifact")" == "packages.tar" ]] && pass "the artifact path carries no colon" || fail "artifact listing"

unpack_packages "$T/artifact" "$T/out" || fail "unpack"
[[ "$(ls "$T/out" | sort | tr '\n' ' ')" == "$PLAIN $EPOCH " && "$(cat "$T/out/$EPOCH")" == epoch ]] \
  && pass "epoch filename and bytes survive the round trip" || fail "round trip: $(ls "$T/out" | tr '\n' ' ')"

# A packages.tar holding anything but top-level package files is refused
# before anything is extracted.
bad() { # bad <description> <tar arguments...>
  local d="$T/bad-$RANDOM"; mkdir -p "$d/in" "$d/out"
  ( cd "$T/built" && tar -cf "$d/in/packages.tar" "${@:2}" )
  if unpack_packages "$d/in" "$d/out" 2>/dev/null; then fail "$1 should be refused"; fi
  [[ -z $(ls -A "$d/out") ]] && pass "refused, nothing extracted: $1" || fail "$1: extracted $(ls -A "$d/out")"
}
ln -s /etc/passwd "$T/built/link-1.0-1-x86_64.pkg.tar.zst"
bad "a symlink named as a package" "$PLAIN" link-1.0-1-x86_64.pkg.tar.zst
rm "$T/built/link-1.0-1-x86_64.pkg.tar.zst"
mkdir -p "$T/built/sub"; cp "$T/built/$PLAIN" "$T/built/sub/"
bad "a package in a subdirectory" "$PLAIN" "sub/$PLAIN"
bad "a file that is no package" "$PLAIN" omarchy.db.tar.zst
bad "a package twice" "$PLAIN" "$PLAIN"
mkdir -p "$T/old"; cp "$T/built/$PLAIN" "$T/old/"
if unpack_packages "$T/old" "$T/out2" 2>/dev/null; then fail "bare files without packages.tar should be refused"; else pass "an artifact without packages.tar is refused"; fi

# The workflows call these bare under `bash -e`, so any non-zero status
# inside them ends the step. (The first version used `shopt -p nullglob`,
# which exits 1 when the option is off; the tests above never saw it because
# `||` suppresses errexit.)
mkdir -p "$T/out4" "$T/out5"
bash -e -c "source '$ROOT/helpers/artifact-helpers.sh'; pack_packages '$T/built' '$T/out4/packages.tar'; tar -tf '$T/out4/packages.tar' >/dev/null; unpack_packages '$T/out4' '$T/out5'" \
  && [[ "$(ls "$T/out5" | sort | tr '\n' ' ')" == "$PLAIN $EPOCH " ]] \
  && pass "pack and unpack succeed under bash -e, as the workflows call them" || fail "bash -e"

mkdir -p "$T/empty"
if pack_packages "$T/empty" "$T/x.tar" 2>/dev/null; then fail "packing an empty build dir should fail"; else pass "empty build dir refused"; fi
if unpack_packages "$T/empty" "$T/out3" 2>/dev/null; then fail "an empty artifact should fail"; else pass "empty artifact refused"; fi
