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
for arch in x86_64 aarch64; do
  mkdir -p "$TEST_ROOT/empty-$arch"
  rm -rf "$TEST_ROOT/plan"
  ARCH="$arch" MIRROR=edge DRY_RUN=true PACKAGES='' \
    OMARCHY_PUBLISHED_REPO_URL="http://127.0.0.1:$port" \
    PKGBUILDS_DIR="$TEST_ROOT/pkgbuilds" HELPERS_DIR="$TEST_ROOT/helpers" \
    FINAL_OUTPUT_DIR="$TEST_ROOT/empty-$arch" BUILD_PLAN_DIR="$TEST_ROOT/plan" \
    timeout 60 "$TEST_ROOT/build/build.sh" > "$TEST_ROOT/plan.log" 2>&1
  grep -q "planning against http://127.0.0.1:$port/edge/$arch" "$TEST_ROOT/plan.log"
  sort "$TEST_ROOT/plan/packages" > "$TEST_ROOT/planned"
  diff -u "$TEST_ROOT/expected" "$TEST_ROOT/planned"
  grep -q 'omarchy 4.0.3-1 - archive already published' "$TEST_ROOT/plan.log"
  printf 'PASS: %s plans against the public channel skip archives it retains\n' "$arch"
done
