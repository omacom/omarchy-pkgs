#!/bin/bash
# Exercise the real local-source prepare and defaults packaging block offline.
set -euo pipefail

if [[ -z ${FAKEROOTKEY:-} ]]; then
  exec fakeroot -- "$0" "$@"
fi

BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

check_metadata() {
  local expected=$1 path=$2 actual
  actual=$(stat -c '%u:%g:%a' "$path")
  if [[ $actual != "$expected" ]]; then
    printf 'FAIL: %s: expected %s, got %s\n' "$path" "$expected" "$actual" >&2
    return 1
  fi
}

for variant in omarchy-settings omarchy-settings-dev; do
  for scenario in standard restrictive permissive; do
    (
      case $scenario in
        standard) file_mode=644; directory_mode=755; umask 022 ;;
        restrictive) file_mode=600; directory_mode=700; umask 077 ;;
        permissive) file_mode=664; directory_mode=775; umask 002 ;;
      esac
      OMARCHY_SRC="$TEST_ROOT/$variant-$scenario/source"
      srcdir="$TEST_ROOT/$variant-$scenario/prepared"
      pkgdir="$TEST_ROOT/$variant-$scenario/package"
      CARCH=x86_64
      mkdir -p "$OMARCHY_SRC/default/docker/rootless" "$srcdir" "$pkgdir"
      for helper in migrate.py rootful-listeners.py volume-manifest.py; do
        printf '# fixture: %s\n' "$helper" > "$OMARCHY_SRC/default/docker/rootless/$helper"
        chmod "$file_mode" "$OMARCHY_SRC/default/docker/rootless/$helper"
      done
      printf 'unrelated default\n' > "$OMARCHY_SRC/default/untouched"
      chmod "$file_mode" "$OMARCHY_SRC/default/untouched"
      chmod "$directory_mode" "$OMARCHY_SRC" "$OMARCHY_SRC/default" "$OMARCHY_SRC/default/docker" "$OMARCHY_SRC/default/docker/rootless"
      # A locally copied checkout must not retain foreign ownership either.
      chown -R 1234:1234 "$OMARCHY_SRC"

      recipe="$BUILD_ROOT/pkgbuilds/$variant/PKGBUILD"
      source "$recipe"
      prepare
      cd "$srcdir/omarchy"

      # Extract, then execute the actual copy/normalization block. This avoids
      # mocking filesystem commands or needing the full desktop source/assets.
      block=$(awk '
        /^  install -d "\$pkgdir\/usr\/share\/omarchy\/default"$/ { active=1 }
        /^  # The Limine template/ { if (active) { complete=1; exit } }
        active { print }
        END { if (!complete) exit 1 }
      ' "$recipe")
      package_defaults() { eval "$block"; }
      package_defaults

      for directory in usr usr/share usr/share/omarchy usr/share/omarchy/default usr/share/omarchy/default/docker usr/share/omarchy/default/docker/rootless; do
        check_metadata 0:0:755 "$pkgdir/$directory"
      done
      for helper in migrate.py rootful-listeners.py volume-manifest.py; do
        check_metadata 0:0:644 "$pkgdir/usr/share/omarchy/default/docker/rootless/$helper"
        cmp "$OMARCHY_SRC/default/docker/rootless/$helper" "$pkgdir/usr/share/omarchy/default/docker/rootless/$helper"
        check_metadata "1234:1234:$file_mode" "$OMARCHY_SRC/default/docker/rootless/$helper"
      done
      check_metadata "1234:1234:$file_mode" "$pkgdir/usr/share/omarchy/default/untouched"
      check_metadata "1234:1234:$directory_mode" "$OMARCHY_SRC/default/docker/rootless"
      printf 'PASS: %s %s source modes and ownership\n' "$variant" "$scenario"
    )
  done
done
