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

out=$(ldd_problems strict <<<"$LDD")
[[ $(wc -l <<<"$out") -eq 4 ]] && pass "an executable fails on every unresolved library or symbol" || fail "executable: $out"
[[ $out == *"libavcodec.so.62 => not found"* ]] && pass "a missing soname is reported" || fail "soname: $out"
[[ $out == *"GLIBC_2.43"* ]] && pass "a missing symbol version is reported" || fail "version: $out"

out=$(ldd_problems plugin <<<"$LDD")
[[ $(wc -l <<<"$out") -eq 3 && $out != *nautilus_menu_item_new* ]] \
  && pass "a plugin's unversioned host symbols are not problems" || fail "shared: $out"

[[ -z $(ldd_problems strict <<<$'\tlibc.so.6 => /usr/lib/libc.so.6 (0x1)') ]] \
  && pass "a fully resolved binary has no problems" || fail "clean binary reported"

[[ $(elf_kind /usr/bin/app "  INTERP  0x318") == strict ]] \
  && pass "an executable is checked strictly" || fail "executable kind"
[[ $(elf_kind /usr/lib/libexample.so.1 "") == strict ]] \
  && pass "a library other programs link is checked strictly" || fail "library kind"
[[ $(elf_kind /usr/lib/nautilus/extensions-4/libext.so "") == plugin ]] \
  && pass "a shared object in a subdirectory is treated as a plugin" || fail "plugin kind"

[[ -z $(inspect_files </dev/null) ]] && pass "a package with no files has no problems" || fail "empty package"
[[ $(printf '%s\n' /usr/lib/python3.14/site-packages/x.py | inspect_files) == rule$'\t'/usr/lib/python3.14/site-packages/x.py$'\t'* ]] \
  && pass "a Python module breaks the fast ring's rule" || fail "Python module accepted"
[[ -z $(printf '%s\n' /usr/bin/bash | inspect_files) ]] && pass "a working binary has no problems" || fail "bash reported"
ldd() { echo "	not a dynamic executable"; return 1; }
out=$(printf '%s\n' /usr/bin/bash | inspect_files) && [[ -z $out ]] \
  && pass "an ELF glibc cannot load (a musl prebuild) does not abort the check" || fail "ldd failure aborted: $out"
unset -f ldd
if pacman -Q qt6-base >/dev/null 2>&1; then
  qt=$(readlink -f /usr/lib/libQt6Gui.so.6)
  [[ -z $(printf '%s\n' "$qt" | inspect_files) ]] \
    && pass "a vendor's Qt-linked library is only link-checked" || fail "vendor Qt flagged"
  [[ $(printf '%s\n' "$qt" | COMPILED=1 inspect_files) == rule$'\t'*libQt6Core* ]] \
    && pass "a Qt-linked library compiled here breaks the rule" || fail "compiled Qt accepted"
fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
tab=$'\t'
cat > "$T/edge" <<OUT
link${tab}/usr/lib/app/libtrace.so${tab}liblttng-ust.so.0 => not found
OUT
cat > "$T/stable" <<OUT
link${tab}/usr/lib/app/libtrace.so${tab}liblttng-ust.so.0 => not found
link${tab}/usr/bin/app${tab}libavcodec.so.62 => not found
rule${tab}/usr/bin/qtapp${tab}links libQt6Core.so.6, which needs rebuilds the fast ring cannot give it
OUT
out=$(channel_failures "$T/edge" "$T/stable")
[[ $out != *liblttng* ]] && pass "a problem edge shares is not the channel's" || fail "shared problem blocked: $out"
[[ $out == *libavcodec.so.62* ]] && pass "a library only edge has blocks the channel" || fail "channel-only problem passed: $out"
[[ $out == *libQt6Core* ]] && pass "a rule problem blocks wherever it happens" || fail "rule problem passed: $out"
: > "$T/clean-edge"
[[ $(channel_failures "$T/clean-edge" "$T/stable" | wc -l) -eq 3 ]] \
  && pass "every channel problem counts when edge has none" || fail "clean edge hid problems"
[[ $(bundled_dir /opt/a/bin/app /opt/b/lib /opt/a/lib) == /opt/a/lib ]] \
  && pass "a binary gets its own bundled copy of a library" || fail "bundled copy from another app"
[[ $(bundled_dir /opt/app/bin/tool /opt/app/bin/assets/legacy/lib /opt/app/bin) == /opt/app/bin ]] \
  && pass "the copy beside the binary beats a deeper one" || fail "deeper bundled copy chosen"
[[ $(channel_failures "$T/stable" "$T/stable") == rule* ]] \
  && pass "rule problems survive comparing a file with itself" || fail "same-file comparison hid rules"
# The fallback for a dependency no channel has still installs the others,
# so their libraries are inspected rather than missing on every channel.
mkdir -p "$T/pkg"
printf '%s\n' 'pkgname = yaru-gtk-theme' 'depend = gtk-engine-murrine' 'depend = gtk3>=3.24' \
  'depend = yaru-icon-theme' 'depend = glib2' > "$T/pkg/.PKGINFO"
bsdtar -cf "$T/a.pkg.tar" -C "$T/pkg" .PKGINFO
printf '%s\n' 'pkgname = yaru-icon-theme' 'provides = yaru-icons=1' 'depend = hicolor-icon-theme' > "$T/pkg/.PKGINFO"
bsdtar -cf "$T/b.pkg.tar" -C "$T/pkg" .PKGINFO
pacman() { local a; for a in "$@"; do [[ $a == -* || $a == 4 ]] || echo "$a"; done > "$T/installed"; }
install_resolvable_dependencies 'warning: cannot resolve "gtk-engine-murrine", a dependency of "yaru-gtk-theme"' "$T/a.pkg.tar" "$T/b.pkg.tar"
unset -f pacman
[[ $(sort "$T/installed" | tr '\n' ' ') == "glib2 gtk3>=3.24 hicolor-icon-theme " ]] \
  && pass "the resolvable dependencies are installed, minus the missing one and the set's own" || fail "installed: $(tr '\n' ' ' < "$T/installed")"
cp "$T/stable" "$T/edge2"
[[ $(channel_failures "$T/edge2" "$T/stable") == rule* ]] && pass "rule problems block even when edge has them" || fail "rule problem excused by edge"

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
