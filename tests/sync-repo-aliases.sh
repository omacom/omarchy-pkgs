#!/bin/bash
# Real repo-add databases and rclone's local backend; no signing or external writes.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export OMARCHY_REPO_ROOT="$T/local"
LOCAL="$T/local/rc/x86_64"
REMOTE="$T/remote/rc/x86_64"
mkdir -p "$LOCAL" "$REMOTE" "$T/pkg" "$T/old"

for rel in 1 2; do
  cat > "$T/pkg/.PKGINFO" <<PKG
pkgname = sample
pkgver = 1-$rel
pkgdesc = alias fixture $rel
arch = x86_64
size = 0
PKG
  bsdtar --zstd -cf "$LOCAL/sample-1-$rel-x86_64.pkg.tar.zst" -C "$T/pkg" .PKGINFO
done
(cd "$T/old" && repo-add --quiet omarchy.db.tar.zst "$LOCAL/sample-1-1-x86_64.pkg.tar.zst")
(cd "$LOCAL" && repo-add --quiet omarchy.db.tar.zst sample-1-2-x86_64.pkg.tar.zst)

sync_repo() {
  "$ROOT/bin/sync-repo" --mirror rc --arch x86_64 --remote "$T/remote" --skip-prod-check > "$T/output" 2>&1
}
fail() { echo "FAIL: $1"; cat "$T/output"; exit 1; }
refuses_without_upload() {
  if sync_repo; then fail "$1 was accepted"; fi
  grep -q 'Local repository alias does not match' "$T/output" || fail "$1 refusal reason"
  [[ -z $(find "$REMOTE" -type f -print -quit) ]] || fail "$1 uploaded files before refusing"
  echo "PASS: $1 refused before upload"
}

for stem in omarchy.db omarchy.files; do
  rm "$LOCAL/$stem"
  cp "$T/old/$stem.tar.zst" "$LOCAL/$stem"
  refuses_without_upload "stale $stem alias"
  rm "$LOCAL/$stem"
  refuses_without_upload "missing $stem alias"
  ln -s missing-target "$LOCAL/$stem"
  refuses_without_upload "broken $stem alias"
  rm "$LOCAL/$stem"
  ln -s "$stem.tar.zst" "$LOCAL/$stem"
  mv "$LOCAL/$stem.tar.zst" "$T/saved-archive"
  ln -s missing-target "$LOCAL/$stem.tar.zst"
  refuses_without_upload "broken $stem.tar.zst archive"
  rm "$LOCAL/$stem.tar.zst"
  mv "$T/saved-archive" "$LOCAL/$stem.tar.zst"
done

sync_repo || fail 'matching symlinks'
for stem in omarchy.db omarchy.files; do
  cmp "$REMOTE/$stem" "$REMOTE/$stem.tar.zst" || fail "$stem remote equality"
done
echo 'PASS: matching symlinks publish equal remote objects'

for stem in omarchy.db omarchy.files; do
  rm "$LOCAL/$stem"
  cp "$LOCAL/$stem.tar.zst" "$LOCAL/$stem"
done
sync_repo || fail 'matching regular files'
echo 'PASS: matching regular files remain supported'

# A directory at one destination name forces a real rclone write failure,
# including when this test runs as root in CI.
mv "$REMOTE/omarchy.db.tar.zst" "$T/remote-archive"
mkdir "$REMOTE/omarchy.db.tar.zst"
if RCLONE_RETRIES=1 RCLONE_LOW_LEVEL_RETRIES=1 sync_repo; then
  fail 'database write failure was accepted'
fi
grep -q 'Repository aliases may disagree' "$T/output" || fail 'partial-upload warning'
rmdir "$REMOTE/omarchy.db.tar.zst"
mv "$T/remote-archive" "$REMOTE/omarchy.db.tar.zst"
echo 'PASS: database write failures warn that aliases may disagree'

# Legacy trees may carry only an alias, without a compressed-name companion.
rm "$LOCAL/omarchy.db.tar.zst" "$LOCAL/omarchy.files.tar.zst"
sync_repo || fail 'standalone database aliases'
echo 'PASS: standalone database aliases remain supported'
