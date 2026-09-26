#!/bin/bash
# Regression for a same-filename rebuild and an already stale remote object.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export OMARCHY_REPO_ROOT="$T/local"
LOCAL="$T/local/rc/x86_64"
REMOTE="$T/remote/rc/x86_64"
FILE=sample-1-1-x86_64.pkg.tar.zst
mkdir -p "$LOCAL" "$REMOTE" "$T/db/sample-1-1"

make_db() { # package file, output database
  local package=$1 output=$2
  cat >"$T/db/sample-1-1/desc" <<EOF
%FILENAME%
$FILE

%NAME%
sample

%VERSION%
1-1

%CSIZE%
$(stat -c %s "$package")

%SHA256SUM%
$(sha256sum "$package" | cut -d' ' -f1)

EOF
  tar --zstd -cf "$output" -C "$T/db" sample-1-1
}

printf 'old' >"$T/old"
printf 'new-package' >"$LOCAL/$FILE"
make_db "$T/old" "$REMOTE/omarchy.db"
cp "$T/old" "$REMOTE/$FILE"
make_db "$LOCAL/$FILE" "$LOCAL/omarchy.db"

sync_repo() {
  "$ROOT/bin/sync-repo" --mirror rc --arch x86_64 \
    --remote "$T/remote" --skip-prod-check >"$T/output" 2>&1
}

if sync_repo; then
  echo 'FAIL: changed digest under an existing filename was accepted'
  exit 1
fi
grep -q 'different checksum in the outgoing database' "$T/output" || { cat "$T/output"; exit 1; }
cmp -s "$REMOTE/$FILE" "$T/old"
echo 'PASS: same-filename rebuild refused before upload'

# The database may already advertise the new build while the remote still
# serves the old bytes (the state reported in #618). A re-run must not publish.
cp "$LOCAL/omarchy.db" "$REMOTE/omarchy.db"
if sync_repo; then
  echo 'FAIL: stale remote object was accepted'
  exit 1
fi
grep -q 'Remote package size does not match' "$T/output" || { cat "$T/output"; exit 1; }
cmp -s "$REMOTE/$FILE" "$T/old"
echo 'PASS: stale remote object refused before database upload'

# Once an operator repairs the object, the same publication can complete.
cp "$LOCAL/$FILE" "$REMOTE/$FILE"
sync_repo
grep -q 'Sync complete' "$T/output"
echo 'PASS: matching object and database publish successfully'
