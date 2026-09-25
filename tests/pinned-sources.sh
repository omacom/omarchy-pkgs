#!/bin/bash
# Every git source in the repository names an immutable commit or a tag.
#
# A source that follows a branch ("#branch=quattro", or no fragment at all)
# produces a package whose contents depend on when it was built, and nothing
# in this repository changes when that branch moves, so the CI publish path,
# which builds what a merge touched, never rebuilds it. Packages that need to
# follow a branch declare a git_branch upstream watch instead, and the tracker
# turns each new tip into a commit pin here (docs/upstream-sources.md).
set -euo pipefail
BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
PKGBUILDS_DIR=${PKGBUILDS_DIR:-$BUILD_ROOT/pkgbuilds}

failures=0
checked=0
for pkgdir in "$PKGBUILDS_DIR"/*/; do
  [[ -f "$pkgdir/PKGBUILD" ]] || continue
  package=$(basename "$pkgdir")
  for arch in x86_64 aarch64; do
    # Sourced the way the build tooling reads recipes: CARCH set, the local
    # source override unset, so conditional and arch-suffixed arrays count.
    sources=$(cd "$pkgdir" && env -u OMARCHY_SRC CARCH="$arch" bash -c '
      source PKGBUILD >/dev/null 2>&1
      printf "%s\n" "${source[@]}" "${source_x86_64[@]}" "${source_aarch64[@]}"' 2>/dev/null) || {
      echo "FAIL: $package: PKGBUILD could not be sourced for $arch"
      failures=$((failures + 1))
      continue
    }
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      url="${entry#*::}"
      [[ "$url" == git+* ]] || continue
      checked=$((checked + 1))
      case "$url" in
        *'#commit='*|*'#tag='*) ;;
        *)
          echo "FAIL: $package ($arch): git source is not pinned to a commit or tag: $url"
          failures=$((failures + 1))
          ;;
      esac
    done <<<"$sources"
  done
done

if ((failures)); then
  echo "$failures unpinned git source(s). Pin with #commit= (and a git_branch upstream watch to move the pin), or #tag= with a checksum."
  exit 1
fi
echo "PASS: $checked git source(s) across pkgbuilds/ are pinned to a commit or tag"
