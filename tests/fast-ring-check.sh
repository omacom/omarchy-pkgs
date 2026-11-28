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
# A promotion only refuses a Python module whose Python the channel lacks,
# once per version, and still checks its files like any other.
out=$(printf '%s\n' /usr/lib/python3.99/site-packages/x.py /usr/lib/python3.99/site-packages/y.py | PROMOTION=1 inspect_files)
[[ $out == link$'\t'/usr/lib/python3.99$'\t'*"no Python 3.99" && $(wc -l <<<"$out") -eq 1 ]] \
  && pass "a promotion refuses a module for a Python the channel lacks, once" || fail "missing Python: $out"
for python in /usr/bin/python3.[0-9]*; do
  [[ -x $python && $python =~ python(3\.[0-9]+)$ ]] || continue
  [[ -z $(printf '%s\n' "/usr/lib/python${BASH_REMATCH[1]}/site-packages/x.py" | PROMOTION=1 inspect_files) ]] \
    && pass "a promotion keeps a module for the channel's own Python" || fail "Python ${BASH_REMATCH[1]} module refused"
  break
done
ldd() { echo "	not a dynamic executable"; return 1; }
out=$(printf '%s\n' /usr/bin/bash | inspect_files) && [[ -z $out ]] \
  && pass "an ELF glibc cannot load (a musl prebuild) does not abort the check" || fail "ldd failure aborted: $out"
unset -f ldd
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# A synthetic ELF linked against a nonexistent Qt6 soname version so the Qt6
# rule and link check run deterministically whether or not qt6-base is installed.
gcc -shared -Wl,-soname,libQt6Core.so.999 -x c /dev/null -o "$T/libQt6Core.so.999"
gcc -shared -Wl,--no-as-needed -Wl,-rpath,'$ORIGIN' "$T/libQt6Core.so.999" -o "$T/libqt-test.so"
out=$(printf '%s\n' "$T/libqt-test.so" | COMPILED=0 inspect_files) && [[ -z $out ]] \
  && pass "a vendor's Qt-linked library is only link-checked" || fail "vendor Qt flagged: $out"
out=$(printf '%s\n' "$T/libqt-test.so" | COMPILED=1 inspect_files) && [[ $out == rule$'\t'*libQt6Core* ]] \
  && pass "a Qt-linked library compiled here breaks the rule" || fail "compiled Qt accepted: $out"
rm "$T/libQt6Core.so.999"
out=$(printf '%s\n' "$T/libqt-test.so" | COMPILED=0 inspect_files) && [[ $out == link$'\t'*libQt6Core.so.999* ]] \
  && pass "a vendor's Qt-linked library still fails link checks when Qt is missing" || fail "missing vendor Qt accepted: $out"
# split_db: the planned entries move from the channel's database to the
# promoted one, so nothing can resolve to a version the promotion replaces.
mkdir -p "$T/chan/keep-1-1" "$T/chan/moved-1-1" "$T/from/moved-1-2" "$T/from/new-1-1" "$T/from/other-1-9"
for e in chan/keep-1-1 chan/moved-1-1 from/moved-1-2 from/new-1-1 from/other-1-9; do
  n=${e#*/}
  printf '%%NAME%%\n%s\n' "${n%-*-*}" > "$T/$e/desc"
done
(cd "$T/chan" && bsdtar -czf "$T/chan.db" -- *)
(cd "$T/from" && bsdtar -czf "$T/from.db" -- *)
split_db "$T/chan.db" "$T/from.db" "$T/promoted.db" moved new
[[ $(bsdtar -tf "$T/promoted.db" | grep '/$' | sort | tr '\n' ' ') == "moved-1-2/ new-1-1/ " \
  && $(bsdtar -tf "$T/chan.db" | grep '/$' | sort | tr '\n' ' ') == "keep-1-1/ " \
  && -z $(bsdtar -tf "$T/promoted.db" | grep '^\./') ]] \
  && pass "the planned entries move to the promoted repository; the rest stay" || fail "split: $(bsdtar -tf "$T/promoted.db" | tr '\n' ' ') / $(bsdtar -tf "$T/chan.db" | tr '\n' ' ')"
cp "$T/chan.db" "$T/chan-before.db"
! split_db "$T/chan.db" "$T/from.db" "$T/missing.db" missing 2>/dev/null && cmp -s "$T/chan.db" "$T/chan-before.db" \
  && pass "a package the source does not have refuses and leaves the channel alone" || fail "split of a missing package"
rm -rf "$T/only" && mkdir -p "$T/only/keep-1-1" && printf '%%NAME%%\nkeep\n' > "$T/only/keep-1-1/desc"
(cd "$T/only" && bsdtar -czf "$T/only.db" -- *)
mkdir -p "$T/from2/keep-1-2" && printf '%%NAME%%\nkeep\n' > "$T/from2/keep-1-2/desc"
(cd "$T/from2" && bsdtar -czf "$T/from2.db" -- *)
split_db "$T/only.db" "$T/from2.db" "$T/promoted2.db" keep && [[ -z $(bsdtar -tf "$T/only.db") ]] \
  && pass "a channel left with no entries gets an empty database" || fail "emptied channel"
bsdtar -czf "$T/empty.db" -T /dev/null
split_db "$T/empty.db" "$T/from2.db" "$T/promoted3.db" keep \
  && [[ $(bsdtar -tf "$T/promoted3.db" | grep '/$') == "keep-1-2/" && -z $(bsdtar -tf "$T/empty.db") ]] \
  && pass "an existing empty channel database splits without error" || fail "empty channel db"

# prepare_view: first promotion (destination 404), normal promotion (200), and
# refusal on server error or missing source.
mkdir -p "$T/view/sync"
printf '[core]\n' > "$T/view/pacman.conf"
prepare() {
  echo "$*" > "$T/view/prepare.args"
  if [[ ${3:-} != --no-omarchy ]]; then
    sed -i '/^\[core\]$/i [omarchy]\nServer = stub\n' "$PACMAN_CONF"
  fi
}
curl() {
  local out="" write="" url=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      -o) out=$2; shift 2 ;;
      -w) write=$2; shift 2 ;;
      -*) shift ;;
      *) url=$1; shift ;;
    esac
  done
  case $url in
    */rc/x86_64/omarchy.db*)
      if [[ $STUB_DEST_CODE == 200 ]]; then cp "$T/chan.db" "$out"; fi
      [[ -n $write ]] && printf '%s' "$STUB_DEST_CODE"
      return "${STUB_DEST_RC:-0}"
      ;;
    */edge/x86_64/omarchy.db*)
      if [[ $STUB_SRC_CODE == 200 ]]; then cp "$T/from.db" "$out"; fi
      if [[ -n $write ]]; then printf '%s' "$STUB_SRC_CODE"; else [[ $STUB_SRC_CODE == 200 ]]; fi
      ;;
  esac
}
PACMAN_CONF="$T/view/pacman.conf" PACMAN_SYNC="$T/view/sync" STUB_DEST_CODE=404 STUB_SRC_CODE=200 \
  prepare_view rc edge x86_64 moved new
[[ $(< "$T/view/prepare.args") == "rc x86_64 --no-omarchy" \
  && ! -e "$T/view/sync/omarchy.db" \
  && $(bsdtar -tf "$T/view/sync/promoted.db" | grep '/$' | sort | tr '\n' ' ') == "moved-1-2/ new-1-1/ " \
  && $(awk '/^\[(promoted|core)\]$/ { print }' "$T/view/pacman.conf" | tr '\n' ' ') == "[promoted] [core] " ]] \
  && ! grep -q '^\[omarchy\]$' "$T/view/pacman.conf" \
  && pass "a first promotion with no destination database prepares an empty view" || fail "first promotion view"
printf '[core]\n' > "$T/view/pacman.conf"
rm -f "$T/view/sync"/*
! PACMAN_CONF="$T/view/pacman.conf" PACMAN_SYNC="$T/view/sync" STUB_DEST_CODE=503 STUB_SRC_CODE=200 \
  prepare_view rc edge x86_64 moved 2>/dev/null \
  && pass "prepare_view refuses a destination server error" || fail "destination 503 accepted"
! PACMAN_CONF="$T/view/pacman.conf" PACMAN_SYNC="$T/view/sync" STUB_DEST_CODE=200 STUB_DEST_RC=18 STUB_SRC_CODE=200 \
  prepare_view rc edge x86_64 moved 2>/dev/null \
  && pass "prepare_view refuses a partial destination download" || fail "partial 200 accepted"
! PACMAN_CONF="$T/view/pacman.conf" PACMAN_SYNC="$T/view/sync" STUB_DEST_CODE=404 STUB_DEST_RC=18 STUB_SRC_CODE=200 \
  prepare_view rc edge x86_64 moved 2>/dev/null \
  && pass "prepare_view refuses a failed 404 probe" || fail "failed 404 accepted"
! PACMAN_CONF="$T/view/pacman.conf" PACMAN_SYNC="$T/view/sync" STUB_DEST_CODE=200 STUB_SRC_CODE=404 \
  prepare_view rc edge x86_64 moved 2>/dev/null \
  && pass "prepare_view refuses a missing source database" || fail "source 404 accepted"
printf '[core]\n' > "$T/view/pacman.conf"
rm -f "$T/view/sync"/*
PACMAN_CONF="$T/view/pacman.conf" PACMAN_SYNC="$T/view/sync" STUB_DEST_CODE=200 STUB_SRC_CODE=200 \
  prepare_view rc edge x86_64 moved new
[[ $(< "$T/view/prepare.args") == "rc x86_64" \
  && $(bsdtar -tf "$T/view/sync/omarchy.db" | grep '/$' | tr '\n' ' ') == "keep-1-1/ " \
  && $(awk '/^\[(promoted|omarchy|core)\]$/ { print }' "$T/view/pacman.conf" | tr '\n' ' ') == "[promoted] [omarchy] [core] " ]] \
  && pass "an existing destination splits [promoted] ahead of [omarchy]" || fail "existing destination view"
unset -f prepare curl
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
install_resolvable_dependencies 'Enter a number (default=1): warning: cannot resolve "gtk-engine-murrine", a dependency of "yaru-gtk-theme"' "$T/a.pkg.tar" "$T/b.pkg.tar"
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
[[ $(channel_mirror rc aarch64) == 'https://arm-rc-mirror.omarchy.org/$arch/$repo' ]] \
  && pass "aarch64 rc resolves to its Arch Linux ARM snapshot" || fail "aarch64 mirror"
drifted=""
for arch in x86_64 aarch64; do
  for channel in stable rc edge; do
    grep -qF "Server = $(channel_mirror "$channel" "$arch")" "$ROOT/build/Dockerfile" || drifted+=" $arch:$channel"
  done
done
[[ -z $drifted ]] && pass "the channel mirrors match build/Dockerfile" || fail "mirrors drifted from build/Dockerfile:$drifted"
grep -qF -- '-e PROMOTION=1' "$ROOT/bin/check-promotion" \
  && pass "check-promotion checks with the promotion's rules" || fail "check-promotion does not set PROMOTION=1"
# promote.yml checks every planned file on the destination before it
# publishes, and publishes only those (linux-omarchy-headers 7.2.15-4,
# 2026-11-23). Commands only: a comment naming them proves nothing.
awk '/^ *#/ { next } /bin\/check-promotion --arch/ { check = NR } /run "\$arch" record\.jsonl --expect / { publish = NR }
  END { exit !(check && publish && check < publish) }' "$ROOT/.github/workflows/promote.yml" \
  && pass "promote.yml checks the promoted files, then publishes only those" || fail "promote.yml publishes without the link check"
! grep -q 'ARCH == aarch64' "$ROOT/bin/check-fast-ring" \
  && pass "aarch64 rc and stable are checked against their own snapshots" || fail "check-fast-ring still skips aarch64's channels"
! grep -rq 'archlinuxarm\.org' "$ROOT/build" "$ROOT/bin" "$ROOT/helpers" \
  && pass "nothing builds or checks against Arch Linux ARM's own mirrors" || fail "Arch Linux ARM's own mirror is still named: $(grep -rl 'archlinuxarm\.org' "$ROOT/build" "$ROOT/bin" "$ROOT/helpers")"
