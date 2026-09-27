#!/bin/bash
# Exercise release/queue handling without publishing to an external repository.
set -euo pipefail
BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export TEST_ROOT
export OMARCHY_STATE_DIR="$TEST_ROOT/state"
unset OMARCHY_REPO_ROOT OMARCHY_KEEP_BUILD_WORKSPACE OMARCHY_DEFER_RUNTIME_DEPS
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state"
cp "$BUILD_ROOT/bin/"{release,auto-release,check-versions} "$TEST_ROOT/bin/"
cp -r "$BUILD_ROOT/helpers" "$BUILD_ROOT/build" "$TEST_ROOT/"
cat >> "$TEST_ROOT/helpers/basecamp-notifier.sh" <<'EOF'
notify_basecamp() { printf '%s\n' "$1" >> "$TEST_ROOT/notifications"; }
EOF

cat > "$TEST_ROOT/bin/build" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "$MODE" == plan ]] && exit 0
out="$TEST_ROOT/build-output/edge/x86_64"
mkdir -p "$out"
echo complete > "$out/good-1-1-x86_64.pkg.tar.zst"
[[ "$MODE" == infrastructure ]] && exit 1
[[ "$MODE" == interrupted ]] && exit 2
mkdir -p "$OMARCHY_BUILD_RESULT_DIR"
: > "$OMARCHY_BUILD_RESULT_DIR/artifacts"
: > "$OMARCHY_BUILD_RESULT_DIR/failed"
: > "$OMARCHY_BUILD_RESULT_DIR/blocked"
if [[ "$MODE" != all_failed ]]; then
  echo good-1-1-x86_64.pkg.tar.zst > "$OMARCHY_BUILD_RESULT_DIR/artifacts"
  mkdir -p "$TEST_ROOT/.publication/edge/x86_64"
  printf '{"jobs":[{"artifacts":[{"filename":"good-1-1-x86_64.pkg.tar.zst"}]}]}\n' > "$TEST_ROOT/.publication/edge/x86_64/manifest.json"
fi
touch "$OMARCHY_BUILD_RESULT_DIR/complete"
[[ "$MODE" == success ]] && exit 0
[[ "$MODE" == missing_artifact ]] && echo missing-1-1-x86_64.pkg.tar.zst >> "$OMARCHY_BUILD_RESULT_DIR/artifacts"
# A failed split build may have copied its first output before failing.
echo incomplete > "$out/bad-first-1-1-x86_64.pkg.tar.zst"
echo bad > "$OMARCHY_BUILD_RESULT_DIR/failed"
echo blocked > "$OMARCHY_BUILD_RESULT_DIR/blocked"
exit 2
EOF
cat > "$TEST_ROOT/bin/repo" <<'EOF'
#!/bin/bash
shift
exec "$(dirname "$0")/release" "$@"
EOF
cat > "$TEST_ROOT/bin/stage" <<'EOF'
#!/bin/bash
set -euo pipefail
stage=$(basename "$0")
echo "$stage" >> "$TEST_ROOT/stages"
out="$TEST_ROOT/build-output/edge/x86_64"
repo="$TEST_ROOT/pkgs.omarchy.org/edge/x86_64"
case "$stage" in
  sign)
    [[ "$MODE" == signing ]] && exit 1
    for file in "$out"/*.pkg.tar.zst; do
      echo "signed $(basename "$file")" >> "$TEST_ROOT/signed"
      touch "$file.sig"
    done
    ;;
  promote-build)
    mkdir -p "$repo"
    mv "$out"/*.pkg.tar.zst* "$repo/"
    ;;
  update-repo)
    mkdir -p "$TEST_ROOT/db/good-1-1"
    printf '%%NAME%%\ngood\n\n%%BASE%%\ngood\n\n%%VERSION%%\n1-1\n' > "$TEST_ROOT/db/good-1-1/desc"
    tar --zstd -cf "$repo/omarchy.db.tar.zst" -C "$TEST_ROOT/db" good-1-1
    ln -s omarchy.db.tar.zst "$repo/omarchy.db"
    ;;
esac
EOF
for stage in sign promote-build clean-repo update-repo sync-repo; do
  cp "$TEST_ROOT/bin/stage" "$TEST_ROOT/bin/$stage"
done
chmod +x "$TEST_ROOT/bin/"*

for package in good bad blocked; do
  mkdir -p "$TEST_ROOT/pkgbuilds/$package/.omarchy"
  printf '{"source":"local"}\n' > "$TEST_ROOT/pkgbuilds/$package/.omarchy/package.json"
  printf "pkgname=%s\npkgver=1\npkgrel=1\narch=('x86_64')\n" "$package" > "$TEST_ROOT/pkgbuilds/$package/PKGBUILD"
done
echo "depends=('bad')" >> "$TEST_ROOT/pkgbuilds/blocked/PKGBUILD"

reset_case() {
  rm -rf "$TEST_ROOT/build-output" "$TEST_ROOT/pkgs.omarchy.org" "$TEST_ROOT/state" "$TEST_ROOT/db" "$TEST_ROOT/.publication"
  mkdir -p "$TEST_ROOT/state"
  : > "$TEST_ROOT/stages"
  : > "$TEST_ROOT/signed"
  : > "$TEST_ROOT/notifications"
  printf 'good\nbad\nblocked\n' > "$TEST_ROOT/state/.sync-needed-edge-x86_64"
}

reset_case
export MODE=partial
if "$TEST_ROOT/bin/auto-release" edge x86_64 > "$TEST_ROOT/partial.log" 2>&1; then
  echo 'FAIL: partial release cleared failure status' >&2; exit 1
fi
[[ $(cat "$TEST_ROOT/stages") == $'sign\npromote-build\nclean-repo\nupdate-repo\nsync-repo' ]]
[[ $(cat "$TEST_ROOT/signed") == 'signed good-1-1-x86_64.pkg.tar.zst' ]]
[[ -f "$TEST_ROOT/pkgs.omarchy.org/edge/x86_64/good-1-1-x86_64.pkg.tar.zst" ]]
[[ ! -e "$TEST_ROOT/pkgs.omarchy.org/edge/x86_64/bad-first-1-1-x86_64.pkg.tar.zst" ]]
[[ -f "$TEST_ROOT/state/.build-failed-edge-x86_64" ]]
grep -q 'Partial release published: edge' "$TEST_ROOT/notifications"
grep -q 'Failed: bad' "$TEST_ROOT/notifications"
grep -q 'Blocked by failed dependencies: blocked' "$TEST_ROOT/notifications"
"$TEST_ROOT/bin/check-versions" > "$TEST_ROOT/versions.log" 2>&1
[[ $(cat "$TEST_ROOT/state/.sync-needed-edge-x86_64") == $'bad\nblocked' ]]
ARCH=x86_64 MIRROR=edge DRY_RUN=true PKGBUILDS_DIR="$TEST_ROOT/pkgbuilds" \
  FINAL_OUTPUT_DIR="$TEST_ROOT/pkgs.omarchy.org/edge/x86_64" HELPERS_DIR="$TEST_ROOT/helpers" \
  "$TEST_ROOT/build/build.sh" > "$TEST_ROOT/retry.log" 2>&1
grep -q 'good - already up to date' "$TEST_ROOT/retry.log"
grep -q 'Build order: bad blocked' "$TEST_ROOT/retry.log"
echo 'PASS: successes publish; incomplete outputs stay out; retries skip published versions'

for MODE in infrastructure interrupted all_failed missing_artifact; do
  export MODE
  reset_case
  if "$TEST_ROOT/bin/release" --mirror edge > "$TEST_ROOT/$MODE.log" 2>&1; then
    echo "FAIL: $MODE succeeded" >&2; exit 1
  fi
  [[ ! -s "$TEST_ROOT/stages" ]]
done
echo 'PASS: infrastructure failures, missing completion records, and zero successes never publish'

reset_case
export MODE=signing
if "$TEST_ROOT/bin/release" --mirror edge > "$TEST_ROOT/signing.log" 2>&1; then
  echo 'FAIL: signing failure succeeded' >&2; exit 1
fi
[[ $(cat "$TEST_ROOT/stages") == sign ]]
echo 'PASS: signing failure stops promotion and sync'

reset_case
export MODE=partial
if OMARCHY_DEFER_RUNTIME_DEPS=true "$TEST_ROOT/bin/release" --mirror edge > "$TEST_ROOT/pair.log" 2>&1; then
  echo 'FAIL: incomplete deferred release pair published' >&2; exit 1
fi
[[ ! -s "$TEST_ROOT/stages" ]]
echo 'PASS: deferred release pairs cannot publish partially'

reset_case
export MODE=success
"$TEST_ROOT/bin/auto-release" edge x86_64 > "$TEST_ROOT/success.log" 2>&1
[[ ! -e "$TEST_ROOT/state/.sync-needed-edge-x86_64" ]]
grep -q 'Release published: edge' "$TEST_ROOT/notifications"
echo 'PASS: complete success publishes and clears the queue'

reset_case
export MODE=plan
"$TEST_ROOT/bin/release" --mirror edge --dry-run > "$TEST_ROOT/plan.log" 2>&1
[[ ! -s "$TEST_ROOT/stages" && ! -s "$TEST_ROOT/notifications" ]]
echo 'PASS: dry runs neither publish nor notify'
