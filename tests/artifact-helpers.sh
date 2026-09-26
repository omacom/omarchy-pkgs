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

# An artifact uploaded before packing existed: bare package files.
mkdir -p "$T/old" "$T/out2"; cp "$T/built"/*.pkg.tar.zst "$T/old/"
unpack_packages "$T/old" "$T/out2" && [[ "$(ls "$T/out2" | sort | tr '\n' ' ')" == "$PLAIN $EPOCH " ]] \
  && pass "a bare pre-packing artifact still unpacks" || fail "bare artifact"

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

# An artifact may be reused across unrelated commits, but never across a
# change to the tools that built it. Use a tiny repository so the test checks
# the actual Git-object input boundary rather than a copy of the hash formula.
keyrepo="$T/keyrepo"
mkdir -p "$keyrepo/bin" "$keyrepo/helpers" "$keyrepo/build" "$keyrepo/.github/workflows"
echo build > "$keyrepo/bin/build"
echo matrix > "$keyrepo/bin/build-matrix"
echo helper > "$keyrepo/helpers/tool.sh"
echo image > "$keyrepo/build/Dockerfile"
echo workflow > "$keyrepo/.github/workflows/build-pr.yml"
git -C "$keyrepo" init -q
git -C "$keyrepo" add .
git -C "$keyrepo" -c user.name=Fixture -c user.email=fixture@example.test commit -qm initial
key_before=$(build_contract_key "$keyrepo")
echo documentation > "$keyrepo/README.md"
git -C "$keyrepo" add README.md
git -C "$keyrepo" -c user.name=Fixture -c user.email=fixture@example.test commit -qm docs
[[ $(build_contract_key "$keyrepo") == "$key_before" ]] \
  && pass "unrelated commits keep the artifact build key" || fail "unrelated commit invalidated artifact"
echo changed >> "$keyrepo/build/Dockerfile"
git -C "$keyrepo" add build/Dockerfile
git -C "$keyrepo" -c user.name=Fixture -c user.email=fixture@example.test commit -qm tooling
[[ $(build_contract_key "$keyrepo") != "$key_before" ]] \
  && pass "build tooling changes invalidate the artifact" || fail "tooling change reused artifact"
