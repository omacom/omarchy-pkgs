#!/bin/bash
# Exercise both settings recipes' actual build()/check() with inert C source.
# This verifies native ELF/linker properties and required-input checks, not the
# production launcher, full makepkg dependency resolution, package(), or install.
set -euo pipefail
export LC_ALL=C

for tool in cc readelf awk grep realpath mktemp mkdir cat cp mv rm uname; do
  if ! command -v "$tool" >/dev/null; then
    printf 'SKIP: settings debug build/check needs %s\n' "$tool"
    exit 0
  fi
done

BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
native_arch=$(uname -m)
case "$native_arch" in
  x86_64|aarch64) ;;
  *) printf 'SKIP: settings recipes do not target native %s\n' "$native_arch"; exit 0 ;;
esac
umask 077
scratch=$(mktemp -d)
trap 'rm -rf -- "${scratch:?}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cat >"$scratch/main.c" <<'C'
int main(void) {
  return 0;
}
C

for recipe in omarchy-settings omarchy-settings-dev; do
  (
    CARCH=$native_arch
    srcdir="$scratch/$recipe/src"
    OMARCHY_SRC="$srcdir/omarchy"
    CFLAGS='-O2 -pipe'
    LDFLAGS='-Wl,--as-needed'
    mkdir -p "$OMARCHY_SRC/default/omarchy/security" "$OMARCHY_SRC/bin" \
      "$OMARCHY_SRC/default/omarchy/command-metadata"
    cp "$scratch/main.c" "$OMARCHY_SRC/default/omarchy/security/omarchy-debug-launcher.c"
    printf '#!/bin/bash\nexit 0\n' >"$OMARCHY_SRC/bin/omarchy-debug"
    printf '# omarchy:summary=Inert debug fixture\n' >"$OMARCHY_SRC/default/omarchy/command-metadata/omarchy-debug"

    # shellcheck disable=SC1090 # Source the recipe, without prepare/package/hooks.
    source "$BUILD_ROOT/pkgbuilds/$recipe/PKGBUILD"
    build
    check || fail "$recipe rejected its valid build and complete input set"

    # Inspect the compiler's artifact, rather than matching flags in the recipe.
    header=$(readelf -W -h "$srcdir/omarchy-debug")
    program=$(readelf -W -l "$srcdir/omarchy-debug")
    dynamic=$(readelf -W -d "$srcdir/omarchy-debug")
    grep -Eq '^[[:space:]]*Type:[[:space:]]+DYN[[:space:]]' <<<"$header" ||
      fail "$recipe did not produce ELF type DYN"
    grep -Eq '\(FLAGS_1\).*PIE' <<<"$dynamic" || fail "$recipe did not produce PIE"
    if grep -Eq '^[[:space:]]*INTERP[[:space:]]' <<<"$program" || grep -Fq '(NEEDED)' <<<"$dynamic"; then
      fail "$recipe build requires a dynamic loader or shared library"
    fi
    "$srcdir/omarchy-debug" || fail "$recipe inert static PIE did not run"
    printf 'PASS: %s %s build/check produces runnable static PIE without INTERP or NEEDED\n' "$recipe" "$CARCH"

    mv "$srcdir/omarchy-debug" "$srcdir/omarchy-debug.static"
    cc -fPIE -pie "$scratch/main.c" -o "$srcdir/omarchy-debug"
    program=$(readelf -W -l "$srcdir/omarchy-debug")
    dynamic=$(readelf -W -d "$srcdir/omarchy-debug")
    # Establish the negative fixture's properties before asking check() to reject it.
    grep -Eq '^[[:space:]]*INTERP[[:space:]]' <<<"$program" && grep -Fq '(NEEDED)' <<<"$dynamic" ||
      fail "$recipe dynamic fixture lacks the expected loader or library dependency"
    if check; then
      fail "$recipe check accepted an ordinary dynamic binary"
    fi
    mv "$srcdir/omarchy-debug.static" "$srcdir/omarchy-debug"
    check || fail "$recipe rejected its restored static PIE"
    printf 'PASS: %s check rejects an ordinary dynamic binary\n' "$recipe"

    for required in bin/omarchy-debug default/omarchy/command-metadata/omarchy-debug; do
      # The previous check passed with this same ELF and both required files.
      mv "$OMARCHY_SRC/$required" "$srcdir/saved-input"
      if check; then
        fail "$recipe check accepted missing $required"
      fi
      mv "$srcdir/saved-input" "$OMARCHY_SRC/$required"
      check || fail "$recipe rejected restored $required"
      printf 'PASS: %s check rejects missing %s and accepts its restoration\n' "$recipe" "$required"
    done
  )
done
