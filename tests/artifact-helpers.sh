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

# ---- plan_slots: one pkgbase, one set of filenames, per architecture --------
mkdir -p "$T/slots/edge/x86_64"
for f in kernel-1-1-x86_64 kernel-headers-1-1-x86_64 stub-2-1-x86_64; do
  echo "$f" > "$T/slots/edge/x86_64/$f.pkg.tar.zst"
done
{
  echo "$T/slots/edge/x86_64/kernel-1-1-x86_64.pkg.tar.zst kernel"
  echo "$T/slots/edge/x86_64/kernel-headers-1-1-x86_64.pkg.tar.zst kernel"
  echo "$T/slots/edge/x86_64/stub-2-1-x86_64.pkg.tar.zst stub"
} > "$T/map"

# A split package's files and a standalone package both reach edge; only the
# split one ships to rc.
out=$(printf 'kernel kernel x86_64 edge,rc x86_64\nstub stub x86_64 edge x86_64\n' | plan_slots "$T/map" "$T/slots/edge" /dev/null)
[[ $(grep -c . <<<"$out") == 2 ]] && pass "plan_slots: one line per channel and architecture" || fail "slot lines: $out"
[[ $(awk '$1=="edge" && $2=="x86_64" {print NF-2}' <<<"$out") == 3 ]] && pass "plan_slots: edge takes every file" || fail "edge files: $out"
[[ $(awk '$1=="rc" && $2=="x86_64" {print NF-2}' <<<"$out") == 2 ]] && pass "plan_slots: rc takes only the package that ships there" || fail "rc files: $out"

# Two recipes that declare one pkgbase publish one filename twice; whichever
# artifact was collected last would silently replace the other (#1878).
out=$(printf 'linux-omarchy kernel x86_64 edge x86_64\nlinux-omarchy-bore kernel x86_64 edge x86_64\n' \
  | plan_slots "$T/map" "$T/slots/edge" /dev/null 2>&1) \
  && fail "two recipes sharing a pkgbase were accepted"
[[ $out == *"linux-omarchy-bore (x86_64) and linux-omarchy both build pkgbase kernel"* ]] \
  && pass "plan_slots: a pkgbase built by two recipes is refused" || fail "refusal: $out"

# An entry that collects no file would publish nothing and read as success.
out=$(printf 'ghost ghost x86_64 edge x86_64\n' | plan_slots "$T/map" "$T/slots/edge" /dev/null 2>&1) \
  && fail "a plan entry with no files was accepted"
[[ $out == *"no package file has pkgbase ghost"* ]] && pass "plan_slots: an entry with no files is refused" || fail "no-file refusal: $out"

# Unless its source is already published: then there is nothing to collect.
echo "ghost x86_64" > "$T/skip"
out=$(printf 'ghost ghost x86_64 edge x86_64\n' | plan_slots "$T/map" "$T/slots/edge" "$T/skip" 2>&1) \
  && [[ -z $out ]] && pass "plan_slots: an already-published entry may have no files" || fail "already-published: ${out:-accepted with output}"
