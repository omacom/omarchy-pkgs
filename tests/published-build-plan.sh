#!/bin/bash
# build/build.sh's dry-run plan, which publish.yml reads to decide what to
# build: it builds new versions and releases, and skips a version the channel
# already indexes or still holds as an older archive.
set -euo pipefail
BUILD_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/pkgbuilds"
cp -r "$BUILD_ROOT/helpers" "$BUILD_ROOT/build" "$TEST_ROOT/"
unset OMARCHY_RC_PINS OMARCHY_DEFER_RUNTIME_DEPS

fixture() {
  local name=$1 version=$2 release=$3
  mkdir -p "$TEST_ROOT/pkgbuilds/$name/.omarchy"
  printf '{"source":"local"}\n' > "$TEST_ROOT/pkgbuilds/$name/.omarchy/package.json"
  cat > "$TEST_ROOT/pkgbuilds/$name/PKGBUILD" <<EOF
pkgname=$name
pkgver=$version
pkgrel=$release
arch=('x86_64' 'aarch64')
EOF
}
fixture omarchy 4.0.3 1
fixture omarchy-settings 4.0.3 1
fixture current 1 1
fixture update 2 1
fixture rebuild 1 2
fixture unindexed 1 1
fixture signature-only 1 1
fixture other-arch 1 1
fixture new-package 1 1
fixture broken-response 1 1
fixture stalled 1 1

db_entry() {
  local name=$1 version=$2
  mkdir -p "$TEST_ROOT/db/$name-$version"
  printf '%%NAME%%\n%s\n\n%%BASE%%\n%s\n\n%%VERSION%%\n%s\n' "$name" "$name" "$version" > "$TEST_ROOT/db/$name-$version/desc"
}
db_entry omarchy 4.0.4rc1-1
db_entry omarchy-settings 4.0.4rc1-1
for package in current update rebuild; do db_entry "$package" 1-1; done
printf '%s\n' broken-response new-package other-arch rebuild signature-only update | sort > "$TEST_ROOT/expected"

for arch in x86_64 aarch64; do
  repo="$TEST_ROOT/pkgs.omarchy.org/edge/$arch"
  mkdir -p "$repo"
  tar --zstd -cf "$repo/omarchy.db.tar.zst" -C "$TEST_ROOT/db" .
  touch "$repo/omarchy-4.0.3-1-$arch.pkg.tar.zst"
  touch "$repo/omarchy-settings-4.0.3-1-any.pkg.tar.xz"
  touch "$repo/unindexed-1-1-$arch.pkg.tar.zst"
  touch "$repo/stalled-1-1-$arch.pkg.tar.zst"
  touch "$repo/rebuild-1-1-$arch.pkg.tar.zst"
  touch "$repo/signature-only-1-1-$arch.pkg.tar.zst.sig"
  other=x86_64
  [[ "$arch" == x86_64 ]] && other=aarch64
  touch "$repo/other-arch-1-1-$other.pkg.tar.zst"


  for selection in '' 'omarchy omarchy-settings current update rebuild unindexed signature-only other-arch new-package broken-response stalled'; do
    ARCH="$arch" MIRROR=edge DRY_RUN=true PACKAGES="$selection" \
      PKGBUILDS_DIR="$TEST_ROOT/pkgbuilds" HELPERS_DIR="$TEST_ROOT/helpers" \
      FINAL_OUTPUT_DIR="$repo" BUILD_PLAN_DIR="$TEST_ROOT/plan" \
      "$TEST_ROOT/build/build.sh" > "$TEST_ROOT/plan.log" 2>&1
    sort "$TEST_ROOT/plan/packages" > "$TEST_ROOT/planned"
    diff -u "$TEST_ROOT/expected" "$TEST_ROOT/planned"
    grep -q 'omarchy 4.0.3-1 - archive already published' "$TEST_ROOT/plan.log"
  done
  printf 'PASS: %s explicit and unscoped plans skip retained archives, allow new versions and releases\n' "$arch"
done

# A package that cross-compiles (package_build_host: chromium for aarch64)
# builds only in its own builder image. An unscoped aarch64 plan in the
# aarch64 image leaves it out; in the x86_64 image it is the only package.
fixture chromium 1 1
for builder in aarch64 x86_64; do
  rm -rf "$TEST_ROOT/plan"
  ARCH=aarch64 BUILDER_ARCH="$builder" MIRROR=edge DRY_RUN=true PACKAGES='' \
    PKGBUILDS_DIR="$TEST_ROOT/pkgbuilds" HELPERS_DIR="$TEST_ROOT/helpers" \
    FINAL_OUTPUT_DIR="$TEST_ROOT/pkgs.omarchy.org/edge/aarch64" BUILD_PLAN_DIR="$TEST_ROOT/plan" \
    "$TEST_ROOT/build/build.sh" > "$TEST_ROOT/plan.log" 2>&1
  sort "$TEST_ROOT/plan/packages" > "$TEST_ROOT/planned"
  if [[ $builder == aarch64 ]]; then
    diff -u "$TEST_ROOT/expected" "$TEST_ROOT/planned"
  else
    diff -u <(echo chromium) "$TEST_ROOT/planned"
  fi
done
rm -rf "$TEST_ROOT/pkgbuilds/chromium"
printf 'PASS: an unscoped aarch64 plan builds chromium only in the x86_64 builder image\n'

# CI has no local published tree: build.sh reads the public channel's
# database, and a retained archive is only there to see over HTTP. Serve the
# same channels and plan against them with nothing mounted. broken-response's
# archive answers 200 with headers curl cannot parse: a transfer that failed,
# which must not count as published. stalled's archive exists, but its "any"
# name never answers: the archive must still count as published, and the plan
# must not hang on it.
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
cat > "$TEST_ROOT/server.py" <<'PY'
import functools, http.server, sys, time

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_HEAD(self):
        if "/broken-response-" in self.path:
            self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Length: nonsense\r\nConnection: close\r\n\r\n")
            return
        if self.path.endswith("/stalled-1-1-any.pkg.tar.zst"):
            time.sleep(3600)
            return
        super().do_HEAD()

    def log_message(self, *args):
        pass

handler = functools.partial(Handler, directory=sys.argv[2])
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), handler).serve_forever()
PY
python3 -I "$TEST_ROOT/server.py" "$port" "$TEST_ROOT/pkgs.omarchy.org" >/dev/null 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null; rm -rf "$TEST_ROOT"' EXIT
for _ in {1..50}; do
  curl -fsS -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && break
  sleep 0.1
done
http_pids=()
for arch in x86_64 aarch64; do
  (
    mkdir -p "$TEST_ROOT/empty-$arch"
    ARCH="$arch" MIRROR=edge DRY_RUN=true PACKAGES='' \
      OMARCHY_PUBLISHED_REPO_URL="http://127.0.0.1:$port" \
      PKGBUILDS_DIR="$TEST_ROOT/pkgbuilds" HELPERS_DIR="$TEST_ROOT/helpers" \
      FINAL_OUTPUT_DIR="$TEST_ROOT/empty-$arch" BUILD_PLAN_DIR="$TEST_ROOT/plan-$arch" \
      timeout 60 "$TEST_ROOT/build/build.sh" > "$TEST_ROOT/plan-$arch.log" 2>&1
    grep -q "planning against http://127.0.0.1:$port/edge/$arch" "$TEST_ROOT/plan-$arch.log"
    sort "$TEST_ROOT/plan-$arch/packages" > "$TEST_ROOT/planned-$arch"
    diff -u "$TEST_ROOT/expected" "$TEST_ROOT/planned-$arch"
    grep -q 'omarchy 4.0.3-1 - archive already published' "$TEST_ROOT/plan-$arch.log"
  ) &
  http_pids+=($!)
done
for pid in "${http_pids[@]}"; do wait "$pid"; done
for arch in x86_64 aarch64; do
  printf 'PASS: %s plans against the public channel skip archives it retains\n' "$arch"
done

# Regression cases for PKGBUILD sourcing (CARCH, OMARCHY_SRC, ./PKGBUILD,
# broken PKGBUILDs, epoch=0), split-package retained archives (including VCS),
# split-package intra-run deps, and staged workspace --prevent-downgrade.
EDGE_ROOT="$TEST_ROOT/edge-cases"
mkdir -p "$EDGE_ROOT/pkgbuilds" "$EDGE_ROOT/db" "$EDGE_ROOT/repo" "$EDGE_ROOT/src" "$EDGE_ROOT/decoy-bin"

# Decoy PKGBUILD on PATH to ensure every read sources ./PKGBUILD, never PATH.
printf '#!/bin/bash\nexit 99\n' > "$EDGE_ROOT/decoy-bin/PKGBUILD"
chmod +x "$EDGE_ROOT/decoy-bin/PKGBUILD"

write_pkg() {
  local dir="$1" body="$2"
  mkdir -p "$EDGE_ROOT/pkgbuilds/$dir/.omarchy"
  printf '{"source":"local"}\n' > "$EDGE_ROOT/pkgbuilds/$dir/.omarchy/package.json"
  printf '%s\n' "$body" > "$EDGE_ROOT/pkgbuilds/$dir/PKGBUILD"
}

write_db_entry() {
  local db_root="$1" name="$2" base="$3" version="$4"
  mkdir -p "$db_root/$name-$version"
  printf '%%NAME%%\n%s\n\n%%BASE%%\n%s\n\n%%VERSION%%\n%s\n' "$name" "$base" "$version" > "$db_root/$name-$version/desc"
}

make_pkg_archive() {
  local out_dir="$1" name="$2" ver="$3"
  local stage="$EDGE_ROOT/pkgstage-$name-$ver"
  mkdir -p "$stage"
  printf 'pkgname = %s\npkgbase = %s\npkgver = %s\narch = x86_64\nsize = 0\n' "$name" "$name" "$ver" > "$stage/.PKGINFO"
  tar --zstd -cf "$out_dir/$name-$ver-x86_64.pkg.tar.zst" -C "$stage" .PKGINFO
}

# 1. CARCH and env -u OMARCHY_SRC during PKGBUILD sourcing
write_pkg carch-pkg 'pkgname=carch-pkg
case "${CARCH:-}" in
  x86_64) pkgver=2.0 ;;
  aarch64) pkgver=3.0 ;;
  *) return 1 ;;
esac
if [[ -n "${OMARCHY_SRC:-}" ]]; then
  pkgver=9.9.9
fi
pkgrel=1
arch=(x86_64 aarch64)'
write_db_entry "$EDGE_ROOT/db" carch-pkg carch-pkg 2.0-1

# 2. epoch=0 formats without 0: prefix; epoch=2 keeps 2: prefix
write_pkg epoch-zero 'pkgname=epoch-zero
epoch=0
pkgver=1.2
pkgrel=3
arch=(x86_64)'
write_db_entry "$EDGE_ROOT/db" epoch-zero epoch-zero 1.2-3

write_pkg epoch-zero-retained 'pkgname=epoch-zero-retained
epoch=0
pkgver=1.0
pkgrel=1
arch=(x86_64)'
write_db_entry "$EDGE_ROOT/db" epoch-zero-retained epoch-zero-retained 2.0-1

write_pkg epoch-pos-current 'pkgname=epoch-pos-current
epoch=2
pkgver=1.2
pkgrel=3
arch=(x86_64)'
write_db_entry "$EDGE_ROOT/db" epoch-pos-current epoch-pos-current 2:1.2-3

write_pkg epoch-pos-update 'pkgname=epoch-pos-update
epoch=2
pkgver=1.2
pkgrel=3
arch=(x86_64)'
write_db_entry "$EDGE_ROOT/db" epoch-pos-update epoch-pos-update 1.2-3

# 3. Split package retained archive (dir/pkgbase != pkgname)
write_pkg split-retained 'pkgbase=split-retained
pkgname=(split-alpha lib-1.0-1-tools)
pkgver=1.0
pkgrel=1
arch=(x86_64)'
write_db_entry "$EDGE_ROOT/db" split-alpha split-retained 2.0-1

write_pkg split-new 'pkgbase=split-new
pkgname=(split-gamma split-delta)
pkgver=1.0
pkgrel=1
arch=(x86_64)'

# 4. Split package intra-run dependency ordering and pre-install by pkgname
write_pkg provider-dir 'pkgbase=provider-dir
pkgname=(provider-lib provider-headers provider-unused)
pkgver=1.0
pkgrel=1
arch=(x86_64)'

write_pkg consumer-pkg 'pkgname=consumer-pkg
epoch=0
pkgver=1.0
pkgrel=1
arch=(x86_64)
makedepends=("provider-headers>=1.0")
depends=(provider-lib)'

# Build local repo + mirror under HTTP server root
HTTP_EDGE="$TEST_ROOT/pkgs.omarchy.org/edge-cases/edge/x86_64"
mkdir -p "$HTTP_EDGE"
tar --zstd -cf "$EDGE_ROOT/repo/omarchy.db.tar.zst" -C "$EDGE_ROOT/db" .
touch "$EDGE_ROOT/repo/epoch-zero-retained-1.0-1-x86_64.pkg.tar.zst"
touch "$EDGE_ROOT/repo/split-alpha-1.0-1-x86_64.pkg.tar.zst"
touch "$EDGE_ROOT/repo/lib-1.0-1-tools-1.0-1-x86_64.pkg.tar.zst"
cp -a "$EDGE_ROOT/repo/." "$HTTP_EDGE/"

# Plan locally with poisoned OMARCHY_SRC and decoy PKGBUILD on PATH
rm -rf "$EDGE_ROOT/plan-local"
PATH="$EDGE_ROOT/decoy-bin:$PATH" OMARCHY_SRC=/poisoned/checkout   ARCH=x86_64 MIRROR=edge DRY_RUN=true \
  PACKAGES="carch-pkg epoch-zero epoch-zero-retained epoch-pos-current epoch-pos-update split-retained split-new consumer-pkg provider-dir" \
  PKGBUILDS_DIR="$EDGE_ROOT/pkgbuilds" HELPERS_DIR="$TEST_ROOT/helpers" \
  FINAL_OUTPUT_DIR="$EDGE_ROOT/repo" BUILD_PLAN_DIR="$EDGE_ROOT/plan-local" \
  OMARCHY_PUBLISHED_REPO_URL="" \
  "$TEST_ROOT/build/build.sh" > "$EDGE_ROOT/plan-local.log" 2>&1

printf '%s\n' epoch-pos-update split-new provider-dir consumer-pkg > "$EDGE_ROOT/expected-order"
diff -u "$EDGE_ROOT/expected-order" "$EDGE_ROOT/plan-local/packages"
diff -u <(printf 'consumer-pkg provider-dir\n') "$EDGE_ROOT/plan-local/dependencies"
grep -q 'split-retained 1.0-1 - archive already published' "$EDGE_ROOT/plan-local.log"
grep -q 'epoch-zero-retained 1.0-1 - archive already published' "$EDGE_ROOT/plan-local.log"
grep -q '+ carch-pkg - already up to date' "$EDGE_ROOT/plan-local.log"
if grep -q 'bad array subscript' "$EDGE_ROOT/plan-local.log"; then
  echo "FAIL: unexpected bash array subscript error in plan-local.log" >&2
  cat "$EDGE_ROOT/plan-local.log" >&2
  exit 1
fi

# Verify CARCH follows ARCH=aarch64 (not hardcoded x86_64)
mkdir -p "$EDGE_ROOT/db-arm" "$EDGE_ROOT/repo-arm"
write_db_entry "$EDGE_ROOT/db-arm" carch-pkg carch-pkg 3.0-1
tar --zstd -cf "$EDGE_ROOT/repo-arm/omarchy.db.tar.zst" -C "$EDGE_ROOT/db-arm" .
rm -rf "$EDGE_ROOT/plan-arm"
PATH="$EDGE_ROOT/decoy-bin:$PATH" OMARCHY_SRC=/poisoned/checkout   ARCH=aarch64 MIRROR=edge DRY_RUN=true PACKAGES="carch-pkg" \
  PKGBUILDS_DIR="$EDGE_ROOT/pkgbuilds" HELPERS_DIR="$TEST_ROOT/helpers" \
  FINAL_OUTPUT_DIR="$EDGE_ROOT/repo-arm" BUILD_PLAN_DIR="$EDGE_ROOT/plan-arm" \
  OMARCHY_PUBLISHED_REPO_URL="" \
  "$TEST_ROOT/build/build.sh" > "$EDGE_ROOT/plan-arm.log" 2>&1
[[ ! -s "$EDGE_ROOT/plan-arm/packages" ]]
grep -q '+ carch-pkg - already up to date' "$EDGE_ROOT/plan-arm.log"
printf 'PASS: CARCH, OMARCHY_SRC unset, ./PKGBUILD, epoch=0, split retained (local), and split dep ordering\n'

# Plan remotely over HTTP for split-retained and epoch-zero-retained
mkdir -p "$EDGE_ROOT/empty-repo"
rm -rf "$EDGE_ROOT/plan-remote"
PATH="$EDGE_ROOT/decoy-bin:$PATH" OMARCHY_SRC=/poisoned/checkout   ARCH=x86_64 MIRROR=edge DRY_RUN=true \
  PACKAGES="carch-pkg epoch-zero epoch-zero-retained split-retained split-new" \
  PKGBUILDS_DIR="$EDGE_ROOT/pkgbuilds" HELPERS_DIR="$TEST_ROOT/helpers" \
  FINAL_OUTPUT_DIR="$EDGE_ROOT/empty-repo" BUILD_PLAN_DIR="$EDGE_ROOT/plan-remote" \
  OMARCHY_PUBLISHED_REPO_URL="http://127.0.0.1:$port/edge-cases" \
  "$TEST_ROOT/build/build.sh" > "$EDGE_ROOT/plan-remote.log" 2>&1
diff -u <(printf 'split-new\n') "$EDGE_ROOT/plan-remote/packages"
grep -q 'split-retained 1.0-1 - archive already published' "$EDGE_ROOT/plan-remote.log"
grep -q 'epoch-zero-retained 1.0-1 - archive already published' "$EDGE_ROOT/plan-remote.log"
printf 'PASS: split-package and epoch=0 retained archives detected over HTTP\n'

# Partial split publication (one sibling present, another missing) must fail closed
# both locally and over HTTP rather than hiding the missing sibling or rebuilding.
write_pkg split-partial 'pkgbase=split-partial
pkgname=(split-part-a split-part-b)
pkgver=1.0
pkgrel=1
arch=(x86_64)'
touch "$EDGE_ROOT/repo/split-part-b-1.0-1-x86_64.pkg.tar.zst"
cp "$EDGE_ROOT/repo/split-part-b-1.0-1-x86_64.pkg.tar.zst" "$HTTP_EDGE/"
for mode in local remote; do
  rm -rf "$EDGE_ROOT/plan-partial-$mode"
  out_dir="$EDGE_ROOT/repo"
  pub_url=""
  if [[ "$mode" == remote ]]; then
    out_dir="$EDGE_ROOT/empty-repo"
    pub_url="http://127.0.0.1:$port/edge-cases"
  fi
  if ARCH=x86_64 MIRROR=edge DRY_RUN=true PACKAGES="split-partial" \
      PKGBUILDS_DIR="$EDGE_ROOT/pkgbuilds" HELPERS_DIR="$TEST_ROOT/helpers" \
      FINAL_OUTPUT_DIR="$out_dir" BUILD_PLAN_DIR="$EDGE_ROOT/plan-partial-$mode" \
      OMARCHY_PUBLISHED_REPO_URL="$pub_url" \
      "$TEST_ROOT/build/build.sh" > "$EDGE_ROOT/plan-partial-$mode.log" 2>&1; then
    echo "FAIL: partially published split package succeeded ($mode)" >&2
    cat "$EDGE_ROOT/plan-partial-$mode.log" >&2
    exit 1
  fi
  grep -q "split-partial 1.0-1 is partially published (missing: split-part-a)" "$EDGE_ROOT/plan-partial-$mode.log"
done
printf 'PASS: partially published split archives fail closed locally and over HTTP\n'

# 5. Broken PKGBUILDs fail closed (both before and after arch=, empty ver, bad epoch)
write_pkg missing-ver 'pkgname=missing-ver
pkgver=""
pkgrel=""
arch=(x86_64)'
write_pkg broken-source 'pkgname=broken-source
pkgver=1.0
pkgrel=1
arch=(x86_64)
return 1'
write_pkg broken-early 'return 1
pkgname=broken-early
pkgver=1.0
pkgrel=1
arch=(x86_64)'
write_pkg broken-epoch 'pkgname=broken-epoch
epoch=abc
pkgver=1.0
pkgrel=1
arch=(x86_64)'

for bad in missing-ver broken-source broken-early broken-epoch; do
  rm -rf "$EDGE_ROOT/plan-$bad"
  if ARCH=x86_64 MIRROR=edge DRY_RUN=true PACKAGES="$bad" \
      PKGBUILDS_DIR="$EDGE_ROOT/pkgbuilds" HELPERS_DIR="$TEST_ROOT/helpers" \
      FINAL_OUTPUT_DIR="$EDGE_ROOT/repo" BUILD_PLAN_DIR="$EDGE_ROOT/plan-$bad" \
      OMARCHY_PUBLISHED_REPO_URL="" \
      "$TEST_ROOT/build/build.sh" > "$EDGE_ROOT/plan-$bad.log" 2>&1; then
    echo "FAIL: broken PKGBUILD $bad succeeded in dry-run plan" >&2
    cat "$EDGE_ROOT/plan-$bad.log" >&2
    exit 1
  fi
  grep -q "Failed to read PKGBUILD" "$EDGE_ROOT/plan-$bad.log"
done
# Unscoped planning (PACKAGES unset) must also fail closed on broken-early
mkdir -p "$EDGE_ROOT/unscoped-bad/broken-early/.omarchy"
cp -a "$EDGE_ROOT/pkgbuilds/broken-early/." "$EDGE_ROOT/unscoped-bad/broken-early/"
rm -rf "$EDGE_ROOT/plan-unscoped-bad"
if ARCH=x86_64 MIRROR=edge DRY_RUN=true PACKAGES="" \
    PKGBUILDS_DIR="$EDGE_ROOT/unscoped-bad" HELPERS_DIR="$TEST_ROOT/helpers" \
    FINAL_OUTPUT_DIR="$EDGE_ROOT/repo" BUILD_PLAN_DIR="$EDGE_ROOT/plan-unscoped-bad" \
    OMARCHY_PUBLISHED_REPO_URL="" \
    "$TEST_ROOT/build/build.sh" > "$EDGE_ROOT/plan-unscoped-bad.log" 2>&1; then
  echo "FAIL: unscoped plan silently dropped broken-early" >&2
  cat "$EDGE_ROOT/plan-unscoped-bad.log" >&2
  exit 1
fi
grep -q "Failed to read PKGBUILD for broken-early" "$EDGE_ROOT/plan-unscoped-bad.log"
printf 'PASS: broken and empty-version PKGBUILDs fail closed in explicit and unscoped planning\n'

# 6. Non-dry-run build_package: intra-run dep pre-install uses pkgname (not dir),
#    mismatched dependency fails closed, and broken PKGBUILD fails before makepkg.
FAKE_BIN="$EDGE_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/sudo" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "/usr/local/bin/pacman-for-makepkg" ]]; then
  printf '%s\n' "$@" > "$FAKE_PACMAN_LOG"
fi
exit 0
EOF
cat > "$FAKE_BIN/makepkg" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "--packagelist" ]]; then
  printf '%s\n' "$PWD/consumer-pkg-1.0-1-x86_64.pkg.tar.zst"
  exit 0
fi
mkdir -p "$PWD/.pkgstage"
printf 'pkgname = consumer-pkg\npkgbase = consumer-pkg\npkgver = 1.0-1\narch = x86_64\nsize = 0\n' > "$PWD/.pkgstage/.PKGINFO"
tar --zstd -cf "$PWD/consumer-pkg-1.0-1-x86_64.pkg.tar.zst" -C "$PWD/.pkgstage" .PKGINFO
EOF
chmod +x "$FAKE_BIN/sudo" "$FAKE_BIN/makepkg"
if ! command -v repo-add >/dev/null 2>&1; then
  cat > "$FAKE_BIN/repo-add" <<'EOF'
#!/bin/bash
if [[ -n "${FAKE_REPO_ADD_ARGS_LOG:-}" ]]; then
  printf '%s\n' "$@" >> "$FAKE_REPO_ADD_ARGS_LOG"
fi
for arg in "$@"; do
  [[ "$arg" == *.db.tar.zst ]] && touch "$arg"
done
exit 0
EOF
  chmod +x "$FAKE_BIN/repo-add"
fi

# Stub check_package_owners so synthetic fixture archives pass
mkdir -p "$EDGE_ROOT/helpers"
cp -a "$TEST_ROOT/helpers/." "$EDGE_ROOT/helpers/"
printf '\ncheck_package_owners() { return 0; }\n' >> "$EDGE_ROOT/helpers/package-owners.sh"

FAKE_PACMAN_LOG="$EDGE_ROOT/pacman-args.log"
rm -f "$FAKE_PACMAN_LOG"
PATH="$EDGE_ROOT/decoy-bin:$FAKE_BIN:$PATH" FAKE_PACMAN_LOG="$FAKE_PACMAN_LOG" \
  OMARCHY_SRC=/poisoned/checkout ARCH=x86_64 MIRROR=edge DRY_RUN=false \
  BUILD_PACKAGE=consumer-pkg BUILD_PLAN_DIR="$EDGE_ROOT/plan-local" \
  PKGBUILDS_DIR="$EDGE_ROOT/pkgbuilds" HELPERS_DIR="$EDGE_ROOT/helpers" \
  SRC_DIR="$EDGE_ROOT/src" BUILD_OUTPUT_DIR="$EDGE_ROOT/build-out" \
  FINAL_OUTPUT_DIR="$EDGE_ROOT/repo" OMARCHY_PUBLISHED_REPO_URL="" \
  "$TEST_ROOT/build/build.sh" > "$EDGE_ROOT/build-consumer.log" 2>&1

grep -q "New package (version: 1.0-1)" "$EDGE_ROOT/build-consumer.log"
grep -Fxq "omarchy-build/provider-lib" "$FAKE_PACMAN_LOG"
grep -Fxq "omarchy-build/provider-headers" "$FAKE_PACMAN_LOG"
if grep -Fxq "omarchy-build/provider-dir" "$FAKE_PACMAN_LOG"; then
  echo "FAIL: pre-install used directory name provider-dir instead of pkgname" >&2
  cat "$FAKE_PACMAN_LOG" >&2
  exit 1
fi
if grep -Fxq "omarchy-build/provider-unused" "$FAKE_PACMAN_LOG"; then
  echo "FAIL: pre-install installed unrelated split subpackage provider-unused" >&2
  cat "$FAKE_PACMAN_LOG" >&2
  exit 1
fi

# Plan mismatch (provider produces no pkgname matching consumer's deps) fails closed
mkdir -p "$EDGE_ROOT/plan-mismatch"
printf 'consumer-pkg\n' > "$EDGE_ROOT/plan-mismatch/packages"
printf 'consumer-pkg split-new\n' > "$EDGE_ROOT/plan-mismatch/dependencies"
if PATH="$FAKE_BIN:$PATH" FAKE_PACMAN_LOG="$EDGE_ROOT/mismatch-pacman.log" \
    ARCH=x86_64 MIRROR=edge DRY_RUN=false \
    BUILD_PACKAGE=consumer-pkg BUILD_PLAN_DIR="$EDGE_ROOT/plan-mismatch" \
    PKGBUILDS_DIR="$EDGE_ROOT/pkgbuilds" HELPERS_DIR="$EDGE_ROOT/helpers" \
    SRC_DIR="$EDGE_ROOT/src" BUILD_OUTPUT_DIR="$EDGE_ROOT/build-out" \
    FINAL_OUTPUT_DIR="$EDGE_ROOT/repo" OMARCHY_PUBLISHED_REPO_URL="" \
    "$TEST_ROOT/build/build.sh" > "$EDGE_ROOT/build-mismatch.log" 2>&1; then
  echo "FAIL: mismatched split provider succeeded instead of failing closed" >&2
  cat "$EDGE_ROOT/build-mismatch.log" >&2
  exit 1
fi
grep -q "No matching package name from split-new for consumer-pkg" "$EDGE_ROOT/build-mismatch.log"
printf 'PASS: intra-run dep pre-install installs needed split pkgnames and fails closed on mismatch\n'

# Broken PKGBUILD also fails closed in build_package before makepkg runs
mkdir -p "$EDGE_ROOT/plan-build-bad"
printf 'missing-ver\n' > "$EDGE_ROOT/plan-build-bad/packages"
: > "$EDGE_ROOT/plan-build-bad/dependencies"
if PATH="$FAKE_BIN:$PATH" FAKE_PACMAN_LOG="$EDGE_ROOT/unused.log" \
    ARCH=x86_64 MIRROR=edge DRY_RUN=false \
    BUILD_PACKAGE=missing-ver BUILD_PLAN_DIR="$EDGE_ROOT/plan-build-bad" \
    PKGBUILDS_DIR="$EDGE_ROOT/pkgbuilds" HELPERS_DIR="$EDGE_ROOT/helpers" \
    SRC_DIR="$EDGE_ROOT/src" BUILD_OUTPUT_DIR="$EDGE_ROOT/build-out" \
    FINAL_OUTPUT_DIR="$EDGE_ROOT/repo" OMARCHY_PUBLISHED_REPO_URL="" \
    "$TEST_ROOT/build/build.sh" > "$EDGE_ROOT/build-bad.log" 2>&1; then
  echo "FAIL: broken PKGBUILD succeeded in build_package" >&2
  cat "$EDGE_ROOT/build-bad.log" >&2
  exit 1
fi
grep -q "Failed to read PKGBUILD version" "$EDGE_ROOT/build-bad.log"
printf 'PASS: broken PKGBUILD fails closed in build_package\n'

# 7. OMARCHY_KEEP_BUILD_WORKSPACE staging order: repo-add --prevent-downgrade
#    keeps 1.10-1 over 1.9-1 and 1:1.0-1 over 2.0-1 despite alphabetical glob order.
SEED_OUT="$EDGE_ROOT/seed-out"
SEED_PLAN="$EDGE_ROOT/plan-seed"
mkdir -p "$SEED_OUT" "$SEED_PLAN"
printf 'consumer-pkg\n' > "$SEED_PLAN/packages"
: > "$SEED_PLAN/dependencies"
make_pkg_archive "$SEED_OUT" foo 1.9-1
make_pkg_archive "$SEED_OUT" foo 1.10-1
touch "$SEED_OUT/foo-1.9-1-x86_64.pkg.tar.zst.sig"
make_pkg_archive "$SEED_OUT" bar 1:1.0-1
make_pkg_archive "$SEED_OUT" bar 2.0-1

FAKE_REPO_ADD_ARGS_LOG="$EDGE_ROOT/repo-add-args.log"
rm -f "$FAKE_REPO_ADD_ARGS_LOG"
PATH="$FAKE_BIN:$PATH" FAKE_PACMAN_LOG="$EDGE_ROOT/unused-seed.log" \
  FAKE_REPO_ADD_ARGS_LOG="$FAKE_REPO_ADD_ARGS_LOG" \
  ARCH=x86_64 MIRROR=edge DRY_RUN=false \
  BUILD_PACKAGE=consumer-pkg BUILD_PLAN_DIR="$SEED_PLAN" \
  PKGBUILDS_DIR="$EDGE_ROOT/pkgbuilds" HELPERS_DIR="$EDGE_ROOT/helpers" \
  SRC_DIR="$EDGE_ROOT/src" BUILD_OUTPUT_DIR="$SEED_OUT" \
  FINAL_OUTPUT_DIR="$EDGE_ROOT/repo" OMARCHY_PUBLISHED_REPO_URL="" \
  "$TEST_ROOT/build/build.sh" > "$EDGE_ROOT/build-seed.log" 2>&1

if command -v repo-add >/dev/null 2>&1; then
  seed_db_entries=$(tar -xOf "$SEED_OUT/omarchy-build.db.tar.zst" --wildcards '*/desc' | awk '
    $0 == "%NAME%" { getline; n=$0 }
    $0 == "%VERSION%" { getline; print n "=" $0 }
  ' | sort)
  grep -Fxq "foo=1.10-1" <<< "$seed_db_entries"
  grep -Fxq "bar=1:1.0-1" <<< "$seed_db_entries"
else
  grep -Fxq -- "--prevent-downgrade" "$FAKE_REPO_ADD_ARGS_LOG"
fi
printf 'PASS: staged workspace seeding preserves highest version (1.10-1 over 1.9-1, 1:1.0-1 over 2.0-1)\n'

# 8. VCS recipes: pinned split VCS skips retained archive, moving #branch= VCS
#    rebuilds despite retained placeholder, and epoch=0 matches unprefixed DB
#    through check_vcs_unchanged (not static-version equality).
VCS_ORIGIN="$EDGE_ROOT/vcs-origin.git"
VCS_WORK="$EDGE_ROOT/vcs-work"
git init --bare -b main "$VCS_ORIGIN" >/dev/null 2>&1
git init -b main "$VCS_WORK" >/dev/null 2>&1
git -C "$VCS_WORK" config user.name test
git -C "$VCS_WORK" config user.email test@example.invalid
echo v1 > "$VCS_WORK/f" && git -C "$VCS_WORK" add f && git -C "$VCS_WORK" commit -m v1 >/dev/null 2>&1
vcs_c1=$(git -C "$VCS_WORK" rev-parse --short=7 HEAD)
echo v2 > "$VCS_WORK/f" && git -C "$VCS_WORK" add f && git -C "$VCS_WORK" commit -m v2 >/dev/null 2>&1
git -C "$VCS_WORK" push "$VCS_ORIGIN" main >/dev/null 2>&1

write_pkg vcs-split-retained 'pkgbase=vcs-split-retained
pkgname=(vcs-split-a vcs-split-b)
pkgver=r100.fdda9d0
pkgrel=1
arch=(x86_64)
source=("repo::git+https://example.invalid/repo.git#commit=fdda9d0cb32604519dbc7fb127058469cb9472be")
pkgver() { echo r100.fdda9d0; }'
write_db_entry "$EDGE_ROOT/db" vcs-split-a vcs-split-retained r101.abcdef0-1

write_pkg vcs-moving "pkgname=vcs-moving
pkgver=r1.g${vcs_c1}
pkgrel=1
arch=(x86_64)
source=(\"repo::git+file://${VCS_ORIGIN}#branch=main\")
pkgver() { echo r2.g0000000; }"
write_db_entry "$EDGE_ROOT/db" vcs-moving vcs-moving "r1.g${vcs_c1}-1"

write_pkg vcs-epoch-zero 'pkgname=vcs-epoch-zero
epoch=0
pkgver=r99.g0000000
pkgrel=1
arch=(x86_64)
source=("repo::git+https://example.invalid/repo.git#commit=fdda9d0cb32604519dbc7fb127058469cb9472be")
pkgver() { echo r100.fdda9d0; }'
write_db_entry "$EDGE_ROOT/db" vcs-epoch-zero vcs-epoch-zero r100.fdda9d0-1

tar --zstd -cf "$EDGE_ROOT/repo/omarchy.db.tar.zst" -C "$EDGE_ROOT/db" .
touch "$EDGE_ROOT/repo/vcs-split-a-r100.fdda9d0-1-x86_64.pkg.tar.zst"
touch "$EDGE_ROOT/repo/vcs-split-b-r100.fdda9d0-1-x86_64.pkg.tar.zst"
touch "$EDGE_ROOT/repo/vcs-moving-r1.g${vcs_c1}-1-x86_64.pkg.tar.zst"

rm -rf "$EDGE_ROOT/plan-vcs"
ARCH=x86_64 MIRROR=edge DRY_RUN=true \
  PACKAGES="vcs-split-retained vcs-moving vcs-epoch-zero" \
  PKGBUILDS_DIR="$EDGE_ROOT/pkgbuilds" HELPERS_DIR="$TEST_ROOT/helpers" \
  FINAL_OUTPUT_DIR="$EDGE_ROOT/repo" BUILD_PLAN_DIR="$EDGE_ROOT/plan-vcs" \
  OMARCHY_PUBLISHED_REPO_URL="" \
  "$TEST_ROOT/build/build.sh" > "$EDGE_ROOT/plan-vcs.log" 2>&1
diff -u <(printf 'vcs-moving\n') "$EDGE_ROOT/plan-vcs/packages"
grep -q 'vcs-split-retained r100.fdda9d0-1 - archive already published' "$EDGE_ROOT/plan-vcs.log"
grep -q '+ vcs-epoch-zero - already up to date' "$EDGE_ROOT/plan-vcs.log"
printf 'PASS: pinned split VCS retained check, moving #branch= VCS rebuild, and VCS epoch=0\n'

# Partial VCS split publication (only vcs-part-a in DB, vcs-part-b missing) fails closed
write_pkg vcs-split-partial 'pkgbase=vcs-split-partial
pkgname=(vcs-part-a vcs-part-b)
pkgver=r99.g0000000
pkgrel=1
arch=(x86_64)
source=("repo::git+https://example.invalid/repo.git#commit=fdda9d0cb32604519dbc7fb127058469cb9472be")
pkgver() { echo r100.fdda9d0; }'
write_db_entry "$EDGE_ROOT/db" vcs-part-a vcs-split-partial r100.fdda9d0-1
tar --zstd -cf "$EDGE_ROOT/repo/omarchy.db.tar.zst" -C "$EDGE_ROOT/db" .
rm -rf "$EDGE_ROOT/plan-vcs-partial"
if ARCH=x86_64 MIRROR=edge DRY_RUN=true PACKAGES="vcs-split-partial" \
    PKGBUILDS_DIR="$EDGE_ROOT/pkgbuilds" HELPERS_DIR="$TEST_ROOT/helpers" \
    FINAL_OUTPUT_DIR="$EDGE_ROOT/repo" BUILD_PLAN_DIR="$EDGE_ROOT/plan-vcs-partial" \
    OMARCHY_PUBLISHED_REPO_URL="" \
    "$TEST_ROOT/build/build.sh" > "$EDGE_ROOT/plan-vcs-partial.log" 2>&1; then
  echo "FAIL: partially published VCS split package succeeded" >&2
  cat "$EDGE_ROOT/plan-vcs-partial.log" >&2
  exit 1
fi
grep -q "vcs-split-partial r100.fdda9d0-1 is partially published (missing: vcs-part-b)" "$EDGE_ROOT/plan-vcs-partial.log"
printf 'PASS: partially published VCS split package fails closed\n'
