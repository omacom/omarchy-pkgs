#!/bin/bash
# The package carries only our own bytes: no Google library or image, nothing
# fetched at build or install time or on a schedule, and a fetch that refuses to
# run in a chroot or without a terminal to accept Google's licence in.
set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

source "$package_dir/PKGBUILD"
for item in "${source[@]}"; do
  [[ $item != *://* ]] || fail "widevine downloads nothing at build time ($item)"
done
[[ $(type -t build) != function && $(type -t prepare) != function ]] ||
  fail "widevine has no build or prepare step"
(( $(vercmp "$pkgver-$pkgrel" 4.10.2891.0-1) > 0 )) || fail "widevine upgrades asahi-alarm's 4.10.2891.0-1"
(( $(vercmp "$pkgver" 4.10.2891.0) >= 0 )) || fail "widevine keeps at least asahi-alarm's pkgver"

srcdir="$scratch/src"
pkgdir="$scratch/pkg"
mkdir -p "$srcdir"
for item in "${source[@]}"; do cp "$package_dir/$item" "$srcdir/"; done
(cd "$srcdir" && package)

while IFS= read -r -d '' path; do
  rel=${path#"$pkgdir"}
  [[ $rel != *.so* && $rel != *libwidevinecdm* ]] || fail "the package ships a path named for the library ($rel)"
  [[ $rel != *squash* ]] || fail "the package ships a path named for an image ($rel)"
done < <(find "$pkgdir" -mindepth 1 -print0)

while IFS= read -r -d '' file; do
  rel=${file#"$pkgdir"}
  magic=$(head -c4 "$file" | od -An -tx1 | tr -d ' \n')
  [[ $magic != 7f454c46 ]] || fail "the package ships an ELF binary ($rel)"
  [[ $magic != 68737173 ]] || fail "the package ships a squashfs image ($rel)"
  (( $(stat -c %s "$file") < 65536 )) || fail "the package ships a large file ($rel)"
done < <(find "$pkgdir" -type f -print0)

cdm=/opt/WidevineCdm/chromium/_platform_specific/linux_arm64/libwidevinecdm.so
[[ -d $pkgdir/opt/WidevineCdm/firefox/gmp-widevinecdm/system-installed ]] || fail "Firefox's GMP directory"
grep -qF 'ln -sfn ../../../chromium/_platform_specific/linux_arm64/libwidevinecdm.so "$GMP_LINK"' "$pkgdir/usr/bin/widevine-fetch" ||
  fail "the fetch links Firefox's GMP directory to the library"
[[ $(readlink "$pkgdir/usr/lib/chromium/WidevineCdm") == /opt/WidevineCdm/chromium ]] || fail "Chromium's WidevineCdm link"
[[ ! -e $pkgdir/usr/lib/systemd ]] || fail "the package ships no systemd units: nothing fetches on its own"
grep -qF "read -r -p \"Type 'accept'" "$pkgdir/usr/bin/widevine-fetch" || fail "the fetch asks for acceptance"
grep -qxF "LACROS_SHA256=$_lacros_sha256" "$pkgdir/usr/lib/widevine/source" || fail "the fetch is pinned to the recipe's sha256"
grep -qF "\"version\": \"$pkgver\"" "$pkgdir/opt/WidevineCdm/chromium/manifest.json" || fail "the manifest names pkgver"

# The scriptlet only tells the user what to run: it never fetches or starts anything.
! grep -vE '^\s*(#|echo )' "$package_dir/widevine.install" | grep -qE 'widevine-fetch( |$)|curl|unsquashfs|widevine_fixup|systemctl (--no-block )?(start|enable|restart)' ||
  fail "the install scriptlet fetches or starts a fetch"
grep -qF "Run 'sudo widevine-fetch'" "$package_dir/widevine.install" || fail "the install message names sudo widevine-fetch"
grep -qF "${cdm%/*/*}" "$package_dir/widevine.install" || fail "removal deletes the fetched library"

# Off a booted system (a container or an image build chroot) the fetch does nothing and succeeds.
out=$(bash "$pkgdir/usr/bin/widevine-fetch" 2>&1) || fail "widevine-fetch fails off a booted system: $out"
[[ $out == *"not on a booted system"* ]] || fail "widevine-fetch refuses off a booted system: $out"

# The fetch itself, on a stand-in system: the booted-system guard and root check
# bypassed, every path under $root, a tar standing in for the Lacros image, and
# stubs for unsquashfs and the patcher. Answers come through a pty.
command -v script >/dev/null || fail "the consent tests need script(1) from util-linux"
root="$scratch/root" stubs="$scratch/stubs"
mkdir -p "$root" "$stubs"
cp -a "$pkgdir/opt" "$root/"
cat > "$stubs/unsquashfs" <<'STUB'
#!/bin/bash
args=() dir="" mode=extract
while (( $# )); do
  case $1 in -q | -n) ;; -l) mode=list ;; -cat) mode=cat ;; -d) dir=$2; shift ;; *) args+=("$1") ;; esac
  shift
done
case $mode in
list) tar -tf "${args[0]}" | sed 's#/$##; s#^#squashfs-root/#' ;;
cat) tar -xOf "${args[0]}" "${args[@]:1}" ;;
extract) mkdir -p "$dir" && tar -xf "${args[0]}" -C "$dir" "${args[@]:1}" ;;
esac
STUB
chmod 755 "$stubs/unsquashfs"
printf 'import shutil, sys\nshutil.copyfile(sys.argv[1], sys.argv[2])\n' > "$scratch/fixup.py"

image() { # image <tar> [licence text]: a stand-in Lacros image
  local tree="$scratch/tree-${1##*/}"
  mkdir -p "$tree/WidevineCdm/_platform_specific/cros_arm64"
  echo "cdm from ${1##*/}" > "$tree/WidevineCdm/_platform_specific/cros_arm64/libwidevinecdm.so"
  [[ -z ${2:-} ]] || printf '%s\n' "$2" > "$tree/WidevineCdm/LICENSE"
  tar -cf "$1" -C "$tree" WidevineCdm
}
prepare() { # prepare <image>: the test copy of the fetch, pinned to this image
  local image=$1
  printf 'WIDEVINE_VERSION=%s\nLACROS_VERSION=0.1\nLACROS_URL=file://%s\nLACROS_SHA256=%s\n' \
    "$pkgver" "$image" "$(sha256sum "$image" | cut -d' ' -f1)" > "$scratch/source"
  sed -e 's#^if \[\[ ! -d /run/systemd/system \]\] || systemd-detect-virt --quiet --chroot; then#if false; then#' \
    -e 's#^(( EUID == 0 )) ||#true ||#' \
    -e "s#/usr/lib/widevine/source#$scratch/source#g" \
    -e "s#/usr/lib/widevine/widevine_fixup.py#$scratch/fixup.py#" \
    -e "s#/opt/WidevineCdm#$root/opt/WidevineCdm#g" -e "s#/var/lib/widevine#$root/var/lib/widevine#g" \
    -e "s#/var/cache/widevine#$root/var/cache/widevine#g" -e "s#/run/widevine#$root/run/widevine#g" \
    "$pkgdir/usr/bin/widevine-fetch" > "$scratch/widevine-fetch"
  ! grep -qE ' /(opt|var|run)/|/usr/lib/widevine/' "$scratch/widevine-fetch" || fail "the test copy still names a system path"
}
fetch() { # fetch <image> <answer> [args]: run the fetch in a pty, answering the prompt
  local answer=$2
  prepare "$1"; shift 2
  printf '%s\n' "$answer" | PATH="$stubs:$PATH" script -qec "bash $scratch/widevine-fetch $*" /dev/null | tr -d '\r'
}
lib=$root${cdm} accepted=$root/var/lib/widevine/accepted
licence='Stand-in licence: you may not patch this.'
image "$scratch/image.tar" "$licence"

# No terminal (a timer, a script, pacman): refused before anything is downloaded.
prepare "$scratch/image.tar"
status=0; out=$(bash "$scratch/widevine-fetch" </dev/null 2>&1) || status=$?
(( status == 1 )) && [[ $out == *"must be accepted in a terminal"* ]] ||
  fail "widevine-fetch refuses without a terminal (exit $status): $out"
[[ ! -e $root/var/cache/widevine ]] || fail "a run without a terminal downloads nothing"

out=$(fetch "$scratch/image.tar" no) && fail "declining exits non-zero: $out"
[[ $out == *"$licence"* && $out == *"not accepted; nothing installed"* ]] || fail "declining shows the licence and stops: $out"
[[ ! -e $lib && ! -e $accepted ]] || fail "declining installs no library and records nothing"

out=$(fetch "$scratch/image.tar" accept) || fail "accepting installs: $out"
[[ $(cat "$lib") == "cdm from image.tar" ]] || fail "accepting installs the patched library"
cmp -s "$root/var/lib/widevine/LICENSE" <(printf '%s\n' "$licence") || fail "the accepted licence is the image's, as shown"
grep -q "^accepted .* by " "$accepted" && grep -qF "licence sha256 $(sha256sum "$root/var/lib/widevine/LICENSE" | cut -d' ' -f1)" "$accepted" ||
  fail "the acceptance record names when, who and which licence"
[[ -L $root/opt/WidevineCdm/firefox/gmp-widevinecdm/system-installed/libwidevinecdm.so ]] || fail "Firefox's GMP link"
out=$(bash "$scratch/widevine-fetch" </dev/null 2>&1) || fail "an accepted install needs no terminal to check: $out"
[[ $out == *"is installed"* ]] || fail "an accepted install is left as it is: $out"

# An image without a licence of its own is shown Google's Chrome terms instead.
image "$scratch/bare.tar"
out=$(fetch "$scratch/bare.tar" accept --force) || fail "accepting the Chrome terms installs: $out"
[[ $out == *"https://www.google.com/chrome/terms/"* ]] || fail "an image without a licence shows the Chrome terms: $out"
grep -qF https://www.google.com/chrome/terms/ "$root/var/lib/widevine/LICENSE" || fail "the Chrome terms are what was accepted"
[[ $(cat "$lib") == "cdm from bare.tar" ]] || fail "the forced fetch installs the new image's library"

# A failed extraction installs nothing, whatever an earlier run left.
rm -rf "$root/var/lib/widevine" "$lib"
printf 'not a tar\n' > "$scratch/broken.tar"
out=$(fetch "$scratch/broken.tar" accept) && fail "a broken image fails: $out"
[[ ! -e $lib && ! -e $accepted ]] || fail "a broken image installs nothing"

echo "ok - widevine"
