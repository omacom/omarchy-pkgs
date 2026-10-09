#!/bin/bash
# Self-test for the parts of helpers/fast-ring-check.sh that decide, from
# `ldd -r` and NEEDED output, whether a binary runs on an older channel.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
source "$ROOT/helpers/fast-ring-check.sh"
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

LDD=$(cat <<'OUT'
	linux-vdso.so.1 (0x00007ffd)
	libavcodec.so.62 => not found
	libc.so.6 => /usr/lib/libc.so.6 (0x00007f)
/usr/bin/app: /usr/lib/libc.so.6: version `GLIBC_2.43' not found (required by /usr/bin/app)
undefined symbol: _ZN7QWidget4showEv, version Qt_6	(/usr/bin/app)
undefined symbol: nautilus_menu_item_new	(/usr/lib/ext.so)
OUT
)

out=$(ldd_problems executable <<<"$LDD")
[[ $(wc -l <<<"$out") -eq 4 ]] && pass "an executable fails on every unresolved library or symbol" || fail "executable: $out"
[[ $out == *"libavcodec.so.62 => not found"* ]] && pass "a missing soname is reported" || fail "soname: $out"
[[ $out == *"GLIBC_2.43"* ]] && pass "a missing symbol version is reported" || fail "version: $out"

out=$(ldd_problems shared <<<"$LDD")
[[ $(wc -l <<<"$out") -eq 3 && $out != *nautilus_menu_item_new* ]] \
  && pass "a plugin's unversioned host symbols are not problems" || fail "shared: $out"

[[ -z $(ldd_problems executable <<<$'\tlibc.so.6 => /usr/lib/libc.so.6 (0x1)') ]] \
  && pass "a fully resolved binary has no problems" || fail "clean binary reported"

out=$(printf '%s\n' libQt6Core.so.6 libpython3.14.so.1.0 libQt5Gui.so.5 libgtk-4.so.1 libc.so.6 | rebuild_sonames)
[[ $out == $'libQt6Core.so.6\nlibpython3.14.so.1.0\nlibQt5Gui.so.5' ]] \
  && pass "Qt and libpython are the sonames that need rebuilds" || fail "rebuild sonames: $out"

[[ $(channel_mirror stable x86_64) == 'https://stable-mirror.omarchy.org/$repo/os/$arch' ]] \
  && pass "stable resolves to its Arch snapshot" || fail "stable mirror"
[[ $(channel_mirror rc aarch64) == *archlinuxarm.org* ]] \
  && pass "aarch64 follows Arch Linux ARM on every channel" || fail "aarch64 mirror"
grep -q "$(channel_mirror stable x86_64)" "$ROOT/build/Dockerfile" \
  && grep -q "$(channel_mirror rc x86_64)" "$ROOT/build/Dockerfile" \
  && pass "the channel mirrors match build/Dockerfile" || fail "mirrors drifted from build/Dockerfile"
