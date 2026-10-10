#!/bin/bash
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export OMARCHY_REPO_ROOT="$T/repo"
unset OMARCHY_RELEASE_LOCK_HELD
REPO="$T/repo/edge/x86_64"
mkdir -p "$REPO" "$T/db/sample-1-1"
for v in 1 2 3 4; do
  printf 'package %s\n' "$v" > "$REPO/sample-$v-1-x86_64.pkg.tar.zst"
  printf 'signature %s\n' "$v" > "$REPO/sample-$v-1-x86_64.pkg.tar.zst.sig"
  touch -t "2026010${v}0000" "$REPO/sample-$v-1-x86_64.pkg.tar.zst"
done
# The indexed version is older on disk than both retained backups.
printf '%%FILENAME%%\nsample-1-1-x86_64.pkg.tar.zst\n\n%%NAME%%\nsample\n\n%%VERSION%%\n1-1\n' > "$T/db/sample-1-1/desc"
tar --zstd -cf "$REPO/omarchy.db.tar.zst" -C "$T/db" sample-1-1
ln -s omarchy.db.tar.zst "$REPO/omarchy.db"
before=$(sha256sum "$REPO/omarchy.db.tar.zst")
bash "$ROOT/bin/clean-repo" --keep 2 --dry-run > "$T/dry-run"
if grep -q 'Would remove: sample-1-' "$T/dry-run"; then
  echo 'FAIL: dry run would remove the indexed package'
  exit 1
fi
grep -q 'Would remove: sample-2-' "$T/dry-run"
[[ -f "$REPO/sample-2-1-x86_64.pkg.tar.zst" ]]
bash "$ROOT/bin/clean-repo" --keep 2 > "$T/clean"
for v in 1 3 4; do
  [[ -f "$REPO/sample-$v-1-x86_64.pkg.tar.zst" ]]
  [[ -f "$REPO/sample-$v-1-x86_64.pkg.tar.zst.sig" ]]
done
[[ ! -e "$REPO/sample-2-1-x86_64.pkg.tar.zst" ]]
[[ ! -e "$REPO/sample-2-1-x86_64.pkg.tar.zst.sig" ]]
[[ "$(sha256sum "$REPO/omarchy.db.tar.zst")" == "$before" ]]
echo 'PASS: dry run and cleanup preserve the indexed package and signature, and prune an unindexed old version'

# Protect both names if an interrupted update leaves different databases.
rm "$REPO/omarchy.db"
sed 's/sample-1-/sample-3-/; s/^1-1$/3-1/' "$T/db/sample-1-1/desc" > "$T/db/desc"
tar -cf "$REPO/omarchy.db" -C "$T/db" desc
bash "$ROOT/bin/clean-repo" --keep 1 > "$T/aliases"
for v in 1 3 4; do [[ -f "$REPO/sample-$v-1-x86_64.pkg.tar.zst" ]]; done
echo 'PASS: both database names retain their indexed files, including an uncompressed alias'

files_before=$(find "$REPO" -type f -name '*.pkg.tar.*' -exec sha256sum {} + | sort)
refuses_without_removal() {
  if bash "$ROOT/bin/clean-repo" --keep 1 > "$T/error" 2>&1; then
    echo 'FAIL: invalid database did not stop cleanup'
    exit 1
  fi
  grep -q 'refusing cleanup' "$T/error"
  [[ "$(find "$REPO" -type f -name '*.pkg.tar.*' -exec sha256sum {} + | sort)" == "$files_before" ]]
}
printf 'broken archive' > "$REPO/omarchy.db"
refuses_without_removal
printf 'not a package record\n' > "$T/db/desc"
tar -cf "$REPO/omarchy.db" -C "$T/db" desc
refuses_without_removal
: > "$T/db/desc"
tar -cf "$REPO/omarchy.db" -C "$T/db" desc
refuses_without_removal
tar -cf "$REPO/omarchy.db" -C "$T/db" sample-1-1 desc
refuses_without_removal
printf '%%NAME%%\nsample\n' > "$T/db/desc"
tar -cf "$REPO/omarchy.db" -C "$T/db" desc
refuses_without_removal
rm "$REPO/omarchy.db"
ln -s missing-database "$REPO/omarchy.db"
refuses_without_removal
echo 'PASS: corrupt, malformed, empty-record, incomplete and dangling databases stop before package deletion'

# Initial publication has no database yet: release cleans before repo-add.
rm "$REPO/omarchy.db" "$REPO/omarchy.db.tar.zst"
bash "$ROOT/bin/clean-repo" --keep 2 > "$T/unindexed"
[[ ! -e "$REPO/sample-1-1-x86_64.pkg.tar.zst" ]]
for v in 3 4; do [[ -f "$REPO/sample-$v-1-x86_64.pkg.tar.zst" ]]; done
echo 'PASS: first publication without a database retains normal cleanup behavior'

tar --zstd -cf "$REPO/omarchy.db.tar.zst" --files-from /dev/null
ln -s omarchy.db.tar.zst "$REPO/omarchy.db"
bash "$ROOT/bin/clean-repo" --keep 1 > "$T/empty"
[[ ! -e "$REPO/sample-3-1-x86_64.pkg.tar.zst" ]]
[[ -f "$REPO/sample-4-1-x86_64.pkg.tar.zst" ]]
echo 'PASS: an empty database permits pruning unindexed versions'
