#!/bin/bash
# Exercise the active publishers with real databases and rclone's local backend.
# Needs repo-add, repo-remove, gpg, bsdtar and rclone (the Arch test container).
# Every operation uses a fresh workdir and regenerates its aliases. Database
# uploads are still multi-object writes, so a failure can leave aliases apart.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export REMOTE="$T/remote" OMARCHY_PUBLISH_PREFIX=''
CHANNEL="$REMOTE/edge/x86_64"
mkdir -p "$T/pkg" "$T/bin"
source "$ROOT/helpers/message-helpers.sh"
source "$ROOT/helpers/repository-aliases.sh"

export GNUPGHOME="$T/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Alias Test <aliases@test>' ed25519 sign 0 2>/dev/null
export GPG_PRIVATE_KEY=$(gpg --batch --armor --export-secret-keys 'Alias Test <aliases@test>')
export GPG_PASSPHRASE=''

mkpkg() {
  cat > "$T/pkg/.PKGINFO" <<PKG
pkgname = $1
pkgbase = $1
pkgver = 1-$2
pkgdesc = database upload fixture
arch = x86_64
size = 0
PKG
  bsdtar --zstd -cf "$T/$1-1-$2-x86_64.pkg.tar.zst" -C "$T/pkg" .PKGINFO
}
for rel in 1 2 3; do mkpkg sample "$rel"; done
mkpkg keeper 1

# Inject an incomplete generated database after running the real package tools.
export REAL_RCLONE=$(command -v rclone)
export REAL_REPO_ADD=$(command -v repo-add) REAL_REPO_REMOVE=$(command -v repo-remove)
for command in repo-add repo-remove; do
  cat > "$T/bin/$command" <<'WRAPPER'
#!/bin/bash
set -euo pipefail
if [[ ${0##*/} == repo-add ]]; then
  "$REAL_REPO_ADD" "$@"
else
  "$REAL_REPO_REMOVE" "$@"
fi
if [[ ${MISSING_DATABASE_ARCHIVE:-0} == 1 ]]; then
  rm omarchy.files.tar.zst
fi
WRAPPER
  chmod +x "$T/bin/$command"
done
# Turn one database destination into a directory only at upload time, after
# the current database has been pulled. The real rclone reports the failure.
export FAILED_DATABASE="$T/previous.db.tar.zst"
cat > "$T/bin/rclone" <<'WRAPPER'
#!/bin/bash
set -euo pipefail
if [[ ${FAIL_DATABASE_UPLOAD:-0} == 1 && ${1:-} == copy ]]; then
  for arg in "$@"; do
    if [[ $arg == '+ omarchy.db*' ]]; then
      mv "$3/omarchy.db.tar.zst" "$FAILED_DATABASE"
      mkdir "$3/omarchy.db.tar.zst"
      break
    fi
  done
fi
exec "$REAL_RCLONE" "$@"
WRAPPER
chmod +x "$T/bin/rclone"
export PATH="$T/bin:$PATH" RCLONE_RETRIES=1 RCLONE_LOW_LEVEL_RETRIES=1

pub() { "$ROOT/bin/publish-artifact" --remote "$REMOTE" --mirror edge --arch x86_64 "$@" > "$T/output" 2>&1; }
unpub() { "$ROOT/bin/unpublish-packages" --remote "$REMOTE" --mirror edge --arch x86_64 sample > "$T/output" 2>&1; }
fail() { echo "FAIL: $1"; cat "$T/output"; exit 1; }
pass() { echo "PASS: $1"; }
matching_aliases() {
  for stem in omarchy.db omarchy.files; do
    cmp -s "$CHANNEL/$stem" "$CHANNEL/$stem.tar.zst" || fail "$stem aliases differ"
  done
}
restore_database() {
  rmdir "$CHANNEL/omarchy.db.tar.zst"
  mv "$FAILED_DATABASE" "$CHANNEL/omarchy.db.tar.zst"
}
expect_upload_failure() {
  local operation=$1; shift
  if FAIL_DATABASE_UPLOAD=1 "$@"; then fail "$operation database failure was accepted"; fi
  grep -q 'Database upload failed' "$T/output" || fail "$operation missing failure diagnostic"
  grep -q 'Some database files may have been updated while others were not' "$T/output" || fail "$operation missing partial-upload warning"
  grep -q 'Repository aliases may disagree. Check the channel before retrying.' "$T/output" || fail "$operation missing recovery warning"
  if grep -Eq '(Published|Removed) [0-9]+ package\(s\)' "$T/output"; then fail "$operation reported success"; fi
  restore_database
  pass "$operation database upload failure warns about inconsistent aliases and exits unsuccessfully"
}

pub "$T/sample-1-1-x86_64.pkg.tar.zst" "$T/keeper-1-1-x86_64.pkg.tar.zst" || fail 'initial publish'
matching_aliases
pass 'initial publication creates matching database and files aliases'

LOCAL="$T/aliases"
mkdir "$LOCAL"
cp "$CHANNEL"/omarchy.* "$LOCAL/"
require_repository_aliases "$LOCAL" || fail 'matching regular aliases'
pass 'matching regular-file aliases remain valid'
for stem in omarchy.db omarchy.files; do
  for fault in stale missing dangling; do
    rm "$LOCAL/$stem"
    case $fault in
      stale) printf stale > "$LOCAL/$stem" ;;
      dangling) ln -s missing-target "$LOCAL/$stem" ;;
    esac
    if require_repository_aliases "$LOCAL" > "$T/output"; then fail "$fault $stem alias accepted"; fi
    rm -f "$LOCAL/$stem"
    cp "$CHANNEL/$stem" "$LOCAL/$stem"
    pass "$fault $stem alias refused"
  done
  rm "$LOCAL/$stem"
  ln -s "$stem.tar.zst" "$LOCAL/$stem"
  mv "$LOCAL/$stem.tar.zst" "$T/archive"
  for fault in missing dangling; do
    [[ $fault != dangling ]] || ln -s missing-target "$LOCAL/$stem.tar.zst"
    if require_repository_aliases "$LOCAL" > "$T/output"; then fail "$fault $stem archive accepted"; fi
    [[ $fault != dangling ]] || rm "$LOCAL/$stem.tar.zst"
    pass "$fault $stem archive refused"
  done
  mv "$T/archive" "$LOCAL/$stem.tar.zst"
done
require_repository_aliases "$LOCAL" || fail 'matching symlink aliases'
pass 'matching symlink aliases remain valid'

snapshot() { find "$CHANNEL" -type f -exec sha256sum {} + | sort; }
refuses_incomplete_database() {
  local operation=$1; shift
  local before
  before=$(snapshot)
  if MISSING_DATABASE_ARCHIVE=1 "$@"; then fail "$operation accepted a missing database archive"; fi
  grep -q 'Database generation is incomplete; refusing upload' "$T/output" || fail "$operation missing preflight diagnostic"
  [[ $(snapshot) == "$before" ]] || fail "$operation uploaded files before refusing"
  pass "$operation refuses a missing database archive before uploading any files"
}
refuses_incomplete_database publish pub "$T/sample-1-2-x86_64.pkg.tar.zst"

# Stale remote aliases cannot become stale local aliases: publishers pull the
# canonical archives and recreate both names rather than reusing a host tree.
printf stale > "$CHANNEL/omarchy.db"
printf stale > "$CHANNEL/omarchy.files"
pub "$T/sample-1-2-x86_64.pkg.tar.zst" || fail 'publish after stale aliases'
matching_aliases
pass 'publishing regenerates aliases from the current database archives'

expect_upload_failure publish pub "$T/sample-1-3-x86_64.pkg.tar.zst"
pub "$T/sample-1-3-x86_64.pkg.tar.zst" || fail 'publish recovery'
matching_aliases
pass 're-running publish repairs aliases after a partial database upload'

refuses_incomplete_database unpublish unpub
unpub || fail 'unpublish'
matching_aliases
pass 'unpublishing creates matching database and files aliases'

pub "$T/sample-1-3-x86_64.pkg.tar.zst" || fail 'republish before unpublish failure'
expect_upload_failure unpublish unpub
unpub || fail 'unpublish recovery'
matching_aliases
pass 're-running unpublish repairs aliases after a partial database upload'
