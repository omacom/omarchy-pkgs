#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

# shellcheck disable=SC1091
source "$package_dir/PKGBUILD"

expected=(
  etc/xdg/walker/config.toml
  etc/xdg/walker/themes/default/item.xml
  etc/xdg/walker/themes/default/item_calc.xml
  etc/xdg/walker/themes/default/item_clipboard.xml
  etc/xdg/walker/themes/default/item_dmenu.xml
  etc/xdg/walker/themes/default/item_files.xml
  etc/xdg/walker/themes/default/item_providerlist.xml
  etc/xdg/walker/themes/default/item_symbols.xml
  etc/xdg/walker/themes/default/item_symbols_grid.xml
  etc/xdg/walker/themes/default/item_archlinuxpkgs.xml
  etc/xdg/walker/themes/default/item_dnfpackages.xml
  etc/xdg/walker/themes/default/item_todo.xml
  etc/xdg/walker/themes/default/item_unicode.xml
  etc/xdg/walker/themes/default/layout.xml
  etc/xdg/walker/themes/default/keybind.xml
  etc/xdg/walker/themes/default/preview.xml
  etc/xdg/walker/themes/default/style.css
)

srcdir="$scratch/src"
pkgdir="$scratch/pkg"
# shellcheck disable=SC2154
repo="$srcdir/${pkgname}-${pkgver}"
mkdir -p "$repo/target/release" "$repo/resources/themes/default"
printf '#!/bin/sh\n' >"$repo/target/release/walker"
printf 'GPL\n' >"$repo/LICENSE"
for rel in "${expected[@]}"; do
  printf 'fixture:%s\n' "$rel" >"$repo/resources/${rel#etc/xdg/walker/}"
done

(cd "$srcdir" && package)

for rel in "${expected[@]}"; do
  [[ -f "$pkgdir/$rel" && ! -L "$pkgdir/$rel" ]] || fail "expected regular packaged config missing: $rel"
  cmp -s "$repo/resources/${rel#etc/xdg/walker/}" "$pkgdir/$rel" || fail "packaged config content mismatch: $rel"
done

actual_etc=$(cd "$pkgdir" && find etc ! -type d | sort)
expected_sorted=$(printf '%s\n' "${expected[@]}" | sort)
# shellcheck disable=SC2154
backup_sorted=$(printf '%s\n' "${backup[@]}" | sort)
[[ "$actual_etc" == "$expected_sorted" ]] || fail "packaged /etc entries drifted from expected walker config set"
[[ "$backup_sorted" == "$expected_sorted" ]] || fail "backup=() drifted from expected walker config set"

echo "ok - walker"
