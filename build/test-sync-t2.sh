#!/bin/bash
# Exercise the real importer with local Git history and a source archive.
set -euo pipefail
root=$(realpath "${BASH_SOURCE[0]%/*}/..")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
real_git=$(command -v git)
mkdir -p "$tmp/work/bin" "$tmp/work/pkgbuilds" "$tmp/shims" "$tmp/upstream"
cp "$root/bin/sync-t2" "$tmp/work/bin/"
cp -a "$root/pkgbuilds/t2fanrd" "$tmp/work/pkgbuilds/"
git -C "$tmp/upstream" init -q
git -C "$tmp/upstream" -c user.name=Test -c user.email=test@example.invalid commit -qm initial --allow-empty
old=$(git -C "$tmp/upstream" rev-parse HEAD)
echo source > "$tmp/upstream/source"
git -C "$tmp/upstream" add source
git -C "$tmp/upstream" -c user.name=Test -c user.email=test@example.invalid commit -qm update
new=$(git -C "$tmp/upstream" rev-parse HEAD)
git -C "$tmp/upstream" archive --format=tar.gz HEAD > "$tmp/source.tar.gz"
sed -i -e "s/^_commit=.*/_commit=$old/" -e "s/^pkgver=.*/pkgver=r1.${old:0:7}/" "$tmp/work/pkgbuilds/t2fanrd/PKGBUILD"

cat > "$tmp/shims/git" <<'EOF'
#!/bin/bash
if [[ $1 == clone ]]; then
  exec "$T2_TEST_GIT" clone --quiet --no-checkout "$T2_TEST_REPO" "${@: -1}"
fi
exec "$T2_TEST_GIT" "$@"
EOF
cat > "$tmp/shims/curl" <<'EOF'
#!/bin/bash
cp "$T2_TEST_ARCHIVE" "${@: -1}"
EOF
chmod +x "$tmp/shims/"*
export T2_TEST_GIT="$real_git" T2_TEST_REPO="$tmp/upstream" T2_TEST_ARCHIVE="$tmp/source.tar.gz"
export PATH="$tmp/shims:$PATH"
recipe="$tmp/work/pkgbuilds/t2fanrd/PKGBUILD"
before=$(sha256sum "$recipe")
"$tmp/work/bin/sync-t2" t2fanrd "$new" --check > "$tmp/check"
[[ $(sha256sum "$recipe") == "$before" ]]
grep -q 'would change' "$tmp/check"
"$tmp/work/bin/sync-t2" t2fanrd "$new" > "$tmp/update"
grep -qx "_commit=$new" "$recipe"
grep -qx "pkgver=r2.${new:0:7}" "$recipe"
grep -qx 'pkgrel=1.1' "$recipe"
grep -q "$(sha256sum "$tmp/source.tar.gz" | cut -d' ' -f1)" "$recipe"
"$tmp/work/bin/sync-t2" t2fanrd "$new" > "$tmp/repeat"
grep -q '0 file(s) updated' "$tmp/repeat"

# Wrong archive, moving ref and downgrade must fail without changing any file.
before=$(sha256sum "$recipe")
if "$tmp/work/bin/sync-t2" t2fanrd "$old" > "$tmp/error" 2>&1; then exit 1; fi
grep -q 'archive does not match' "$tmp/error"
[[ $(sha256sum "$recipe") == "$before" ]]
git -C "$tmp/upstream" archive --format=tar.gz "$old" > "$tmp/source.tar.gz"
if "$tmp/work/bin/sync-t2" t2fanrd "$old" > "$tmp/error" 2>&1; then exit 1; fi
grep -q 'Refusing downgrade' "$tmp/error"
[[ $(sha256sum "$recipe") == "$before" ]]
if "$tmp/work/bin/sync-t2" t2fanrd main > "$tmp/error" 2>&1; then exit 1; fi
[[ $(sha256sum "$recipe") == "$before" ]]
echo 'PASS: update preview, pinned import, checksums, repeat, wrong archive, downgrade and moving-ref rejection'
