#!/bin/bash
# Unit tests for bin/check-shadowed: verifies x86_64 (core/extra/multilib) and
# aarch64 (core/extra/alarm/aur) shadow detection, pacman repo resolution order,
# epoch version comparison, single-arch vs all-arch unused checks, libalpm DB
# member boundaries (including ALARM all-NUL records), exit code 2 on
# mirror/archive failures, dual-arch partial outage preservation, and
# check-shadowed.yml workflow invariants.
set -euo pipefail

ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# Build a pacman sync database archive (.db) from "name version" pairs using
# repo-add layout (top-level <name>-<ver>/desc without leading ./).
# Supports gzip (default) or zstd compression via 2nd arg.
make_db() {
  local dest="$1" comp="${2:-gzip}"
  shift 2
  local stage
  stage=$(mktemp -d "$T/db.XXXXXX")
  mkdir -p "$(dirname "$dest")"

  local entry name ver dir entries=()
  for entry in "$@"; do
    name="${entry%% *}"
    ver="${entry#* }"
    dir="${name}-${ver}"
    mkdir -p "$stage/$dir"
    printf "%%FILENAME%%\n%s-%s-any.pkg.tar.zst\n\n%%NAME%%\n%s\n\n%%BASE%%\n%s\n\n%%VERSION%%\n%s\n\n" \
      "$name" "$ver" "$name" "$name" "$ver" > "$stage/$dir/desc"
    entries+=("$dir")
  done

  if (( ${#entries[@]} == 0 )); then
    tar -cf - -T /dev/null | gzip -c > "$dest"
  elif [[ "$comp" == "zstd" ]]; then
    (cd "$stage" && tar -cf - -- "${entries[@]}") | zstd -q -c > "$dest"
  else
    (cd "$stage" && tar -cf - -- "${entries[@]}") | gzip -c > "$dest"
  fi
  rm -rf "$stage"
}

recipe() { # recipe <dir> <pkgname> <pkgver> <pkgrel> <arches> [epoch]
  local dir="$1" pkgname="$2" pkgver="$3" pkgrel="$4" arches="$5" epoch="${6:-}"
  mkdir -p "$T/pkgbuilds/$dir/.omarchy"
  echo '{"source": "local"}' > "$T/pkgbuilds/$dir/.omarchy/package.json"
  {
    printf "pkgname=(%s)\n" "$pkgname"
    printf "pkgver=%s\n" "$pkgver"
    printf "pkgrel=%s\n" "$pkgrel"
    [[ -n "$epoch" ]] && printf "epoch=%s\n" "$epoch"
    printf "arch=(%s)\n" "$arches"
  } > "$T/pkgbuilds/$dir/PKGBUILD"
}

# Build mirrors once; error-path tests copy lightweight mirror dirs.
make_db "$T/arch-mirror/core/os/x86_64/core.db" gzip \
  "linux-core-pkg 1.0-1" \
  "dup-pkg 1.0-1"
make_db "$T/arch-mirror/extra/os/x86_64/extra.db" gzip \
  "foo 2.0-1" \
  "epoch-pkg 1:1.0-1" \
  "x86-only-shadow 1.0-1" \
  "dup-pkg 9.9-1"
make_db "$T/arch-mirror/multilib/os/x86_64/multilib.db" zstd \
  "lib32-bar 3.0-1"

make_db "$T/arm-mirror/aarch64/core/core.db" gzip \
  "linux-firmware-qcom 20261124-1" \
  "dup-arm 1.0-1"
make_db "$T/arm-mirror/aarch64/extra/extra.db" gzip \
  "foo 2.0-1" \
  "cuda 13.5.0-1" \
  "alsa-ucm-conf 1.2.16.1-1" \
  "epoch-pkg 1:1.0-1" \
  "dup-arm 9.9-1"
make_db "$T/arm-mirror/aarch64/alarm/alarm.db" gzip \
  "alarm-tool 4.0-1" \
  "any-alarm-only 2.0-1"
make_db "$T/arm-mirror/aarch64/aur/aur.db" zstd \
  "alarm-aur-pkg 5.0-1"

setup_clean_tree() {
  rm -rf "$T/pkgbuilds"
  mkdir -p "$T/pkgbuilds"

  recipe foo foo 2.0 1 "x86_64 aarch64"
  recipe x86-only-shadow x86-only-shadow 1.0 1.1 "x86_64"
  recipe lib32-bar lib32-bar 3.0 1 "x86_64"
  recipe alsa-ucm-conf alsa-ucm-conf 1.2.16.1.r45 7 "aarch64"
  recipe alarm-tool alarm-tool 4.0 2 "aarch64"
  recipe alarm-aur-pkg alarm-aur-pkg 5.0 1 "aarch64"
  recipe epoch-pkg epoch-pkg 1.0 1 "any" 1
  recipe dup-pkg dup-pkg 1.0 1 "x86_64"
  recipe dup-arm dup-arm 1.0 1 "aarch64"
  recipe unshadowed-pkg unshadowed-pkg 1.0 1 "x86_64 aarch64"

  cat << 'LIST' > "$T/shadowed-packages.txt"
# Test shadow list
foo Dual-arch shadow
x86-only-shadow x86_64-only shadow
lib32-bar multilib shadow
alsa-ucm-conf aarch64 extra shadow
alarm-tool aarch64 alarm shadow
alarm-aur-pkg aarch64 aur shadow
epoch-pkg Epoch shadow on any
dup-pkg Precedence check on x86_64
dup-arm Precedence check on aarch64
LIST
}

ARCH_MIRROR="$T/arch-mirror"
ARM_MIRROR="$T/arm-mirror/aarch64"

run_check() {
  local rc=0
  OUT=$(
    OMARCHY_PKGBUILDS="$T/pkgbuilds" \
    OMARCHY_SHADOW_LIST="$T/shadowed-packages.txt" \
    OMARCHY_ARCH_MIRROR_URL="file://$ARCH_MIRROR" \
    OMARCHY_ALARM_BASE_URL="file://$ARM_MIRROR" \
    "$ROOT/bin/check-shadowed" "$@" 2>&1
  ) || rc=$?
  return "$rc"
}

assert_has() {
  grep -qF "$1" <<<"$OUT" || fail "$2 (missing '$1'): $OUT"
}

expect_rc() {
  local want_rc="$1" msg="$2"
  shift 2
  local rc=0
  run_check "$@" || rc=$?
  (( rc == want_rc )) || fail "$msg (expected rc=$want_rc, got rc=$rc): $OUT"
}

setup_clean_tree

# 1. Clean full-tree passes on both x86_64 and aarch64 (including repo precedence & zstd DBs)
run_check || fail "clean tree should pass: $OUT"
assert_has "[x86_64]" "clean tree reports x86_64"
assert_has "[aarch64]" "clean tree reports aarch64"
pass "clean tree passes across both x86_64 (core/extra/multilib) and aarch64 (core/extra/alarm/aur)"

# 2. Stale & undeclared shadows across all aarch64 repos (core, extra, alarm, aur) and x86_64 (multilib, epoch)
recipe linux-firmware-qcom linux-firmware-qcom 20261019 1.1 "aarch64"
recipe cuda cuda 13.4.2 1 "aarch64"
recipe alarm-tool-old alarm-tool 3.9 1 "aarch64"
recipe alarm-aur-old alarm-aur-pkg 4.9 1 "aarch64"
recipe any-alarm-only any-alarm-only 1.0 1 "any"
recipe lib32-old lib32-bar 2.9 1 "x86_64"
recipe epoch-old epoch-pkg 2.0 1 "any"
cat << 'EXTRA' >> "$T/shadowed-packages.txt"
linux-firmware-qcom Firmware backports
any-alarm-only Test any-arch alarm shadow
EXTRA

expect_rc 1 "dual-arch findings" -- \
  linux-firmware-qcom cuda alarm-tool-old alarm-aur-old any-alarm-only lib32-old epoch-old
assert_has "[aarch64] linux-firmware-qcom shadows core/linux-firmware-qcom with an older build" "aarch64 core stale"
assert_has "[aarch64] cuda shadows extra/cuda (ours 13.4.2-1, extra 13.5.0-1)" "aarch64 extra undeclared with versions"
assert_has "[aarch64] alarm-tool shadows alarm/alarm-tool with an older build" "aarch64 alarm stale"
assert_has "[aarch64] alarm-aur-pkg shadows aur/alarm-aur-pkg with an older build" "aarch64 aur stale"
assert_has "[aarch64] any-alarm-only shadows alarm/any-alarm-only with an older build" "arch=(any) alarm stale"
assert_has "[x86_64] lib32-bar shadows multilib/lib32-bar with an older build" "x86_64 multilib stale"
assert_has "[x86_64] epoch-pkg shadows extra/epoch-pkg with an older build: ours 2.0-1, extra 1:1.0-1" "x86_64 epoch stale"
assert_has "[aarch64] epoch-pkg shadows extra/epoch-pkg with an older build: ours 2.0-1, extra 1:1.0-1" "aarch64 epoch stale"
pass "catches stale & undeclared shadows across all x86_64 & aarch64 repos including epochs and arch=(any)"

# 3. Single-arch flags (--arch and --arch=) isolate architectures without false unused errors
setup_clean_tree
recipe cuda cuda 13.4.2 1 "aarch64"
echo "cuda N1x CUDA carry" >> "$T/shadowed-packages.txt"
run_check --arch x86_64 || fail "--arch x86_64 should ignore aarch64-only stale cuda and not flag aarch64 entries unused: $OUT"
expect_rc 1 "--arch=aarch64 stale cuda" --arch=aarch64 -- cuda
assert_has "[aarch64] cuda shadows extra/cuda with an older build" "--arch=aarch64 stale cuda msg"

setup_clean_tree
recipe lib32-bar lib32-bar 2.9 1 "x86_64"
run_check --arch=aarch64 || fail "--arch=aarch64 should ignore x86_64-only stale lib32-bar and not flag x86_64 entries unused: $OUT"
pass "--arch x86_64 and --arch aarch64 isolate checks without false unused errors"

# 4. Unused entry fails full-tree all-arch run, skipped on named package run
setup_clean_tree
echo "ghost-pkg No longer exists anywhere" >> "$T/shadowed-packages.txt"
expect_rc 1 "unused shadow entry on full-tree run"
assert_has "lists ghost-pkg, which shadows nothing" "unused entry message"
run_check -- foo || fail "named package check with -- should ignore unrelated unused list entries: $OUT"
pass "unused list entry fails full-tree all-arch check and is skipped for named packages"

# 5. Invalid CLI options and unreadable PKGBUILD exit 1
expect_rc 1 "invalid --arch" --arch riscv64
assert_has "Invalid architecture" "invalid --arch msg"
expect_rc 1 "unknown flag" --bogus-flag
assert_has "Unknown option" "unknown flag msg"
mkdir -p "$T/pkgbuilds/broken/.omarchy"
echo '{"source": "local"}' > "$T/pkgbuilds/broken/.omarchy/package.json"
echo "return 1" > "$T/pkgbuilds/broken/PKGBUILD"
expect_rc 1 "unreadable PKGBUILD" --arch x86_64 -- broken
assert_has "could not read pkgname and pkgver" "unreadable PKGBUILD msg"
pass "invalid CLI options and unreadable PKGBUILD fail with exit 1"

# 6. Operational errors (unreachable mirror, corrupt/truncated DB, empty DB, invalid entry) exit 2
cp -a "$T/arm-mirror" "$T/arm-missing"
rm -f "$T/arm-missing/aarch64/alarm/alarm.db"
ARM_MIRROR="$T/arm-missing/aarch64" expect_rc 2 "missing repo DB" --arch aarch64 -- foo
assert_has "could not be fetched" "missing repo DB msg"

cp -a "$T/arm-mirror" "$T/arm-corrupt"
printf "not a tar archive" > "$T/arm-corrupt/aarch64/extra/extra.db"
ARM_MIRROR="$T/arm-corrupt/aarch64" expect_rc 2 "corrupt repo DB" --arch aarch64 -- foo
assert_has "is unreadable" "corrupt repo DB msg"

cp -a "$T/arm-mirror" "$T/arm-trunc"
head -c 60 "$T/arm-mirror/aarch64/extra/extra.db" > "$T/arm-trunc/aarch64/extra/extra.db"
ARM_MIRROR="$T/arm-trunc/aarch64" expect_rc 2 "truncated repo DB" --arch aarch64 -- foo
assert_has "is unreadable" "truncated repo DB msg"

cp -a "$T/arm-mirror" "$T/arm-membercut"
stage=$(mktemp -d "$T/membercut.XXXXXX")
mkdir -p "$stage/one-1.0-1" "$stage/two-1.0-1"
printf "%%NAME%%\none\n\n%%VERSION%%\n1.0-1\n\n" > "$stage/one-1.0-1/desc"
printf "%%NAME%%\ntwo\n\n%%VERSION%%\n1.0-1\n\n" > "$stage/two-1.0-1/desc"
(cd "$stage" && tar -cf "$stage/full.tar" one-1.0-1/desc two-1.0-1/desc)
head -c 1024 "$stage/full.tar" | gzip -c > "$T/arm-membercut/aarch64/extra/extra.db"
rm -rf "$stage"
ARM_MIRROR="$T/arm-membercut/aarch64" expect_rc 2 "member-boundary truncated DB without EOF zero blocks" --arch aarch64 -- foo
assert_has "is unreadable" "member-boundary truncated DB msg"

cp -a "$T/arm-mirror" "$T/arm-badcrc"
stage=$(mktemp -d "$T/badcrc.XXXXXX")
mkdir -p "$stage/one-1.0-1"
printf "%%NAME%%\none\n\n%%VERSION%%\n1.0-1\n\n" > "$stage/one-1.0-1/desc"
(cd "$stage" && tar -cf "$stage/padded.tar" one-1.0-1/desc)
dd if=/dev/zero bs=1024 count=64 status=none >> "$stage/padded.tar"
gzip -c "$stage/padded.tar" > "$T/arm-badcrc/aarch64/extra/extra.db"
sz=$(wc -c < "$T/arm-badcrc/aarch64/extra/extra.db")
printf "\x00\x00\x00\x00" | dd of="$T/arm-badcrc/aarch64/extra/extra.db" bs=1 seek=$((sz - 8)) conv=notrunc status=none
rm -rf "$stage"
ARM_MIRROR="$T/arm-badcrc/aarch64" expect_rc 2 "padded gzip DB with corrupted CRC" --arch aarch64 -- foo
assert_has "crc error" "padded bad-CRC DB msg"

TMPDIR="$T/nonexistent-tmpdir" expect_rc 2 "mktemp failure exits 2" --arch aarch64 -- foo
assert_has "Could not create temporary directory" "mktemp failure msg"

cp -a "$T/arch-mirror" "$T/arch-empty"
make_db "$T/arch-empty/multilib/os/x86_64/multilib.db" gzip
ARCH_MIRROR="$T/arch-empty" expect_rc 2 "empty repo DB" --arch x86_64 -- foo
assert_has "lists no packages" "empty repo DB msg"

cp -a "$T/arm-mirror" "$T/arm-badentry"
stage=$(mktemp -d "$T/badentry.XXXXXX")
mkdir -p "$stage/badname"
printf "%%NAME%%\nbadname\n\n%%VERSION%%\n1.0-1\n\n" > "$stage/badname/desc"
(cd "$stage" && tar -cf - badname) | gzip -c > "$T/arm-badentry/aarch64/extra/extra.db"
rm -rf "$stage"
ARM_MIRROR="$T/arm-badentry/aarch64" expect_rc 2 "invalid DB entry name" --arch aarch64 -- foo
assert_has "reported errors reading" "invalid DB entry msg"
pass "operational errors (missing, corrupt, truncated, empty, invalid DB entry) exit 2"

# 7. libalpm preserves member boundaries and handles ALARM all-NUL desc records
# without breaking ARM checking or cross-contaminating adjacent records.
cp -a "$T/arm-mirror" "$T/arm-degraded"
stage=$(mktemp -d "$T/degraded.XXXXXX")
mkdir -p "$stage/foo-2.0-1" "$stage/findnewest-0.3-4" "$stage/first-1.0-1" "$stage/second-2.0-1"
printf "%%FILENAME%%\nfoo-2.0-1-aarch64.pkg.tar.zst\n\n%%NAME%%\nfoo\n\n%%VERSION%%\n2.0-1\n\n" > "$stage/foo-2.0-1/desc"
dd if=/dev/zero of="$stage/findnewest-0.3-4/desc" bs=1 count=200 status=none
printf "%%FILENAME%%\nfirst-1.0-1-aarch64.pkg.tar.zst\n\n%%NAME%%\nfirst\n\n" > "$stage/first-1.0-1/desc"
printf "%%VERSION%%\n2.0-1\n\n%%NAME%%\nsecond\n\n" > "$stage/second-2.0-1/desc"
(cd "$stage" && tar -cf - foo-2.0-1 findnewest-0.3-4 first-1.0-1 second-2.0-1) | gzip -c > "$T/arm-degraded/aarch64/extra/extra.db"
rm -rf "$stage"

setup_clean_tree
recipe findnewest findnewest 0.2 1 "aarch64"
recipe first first 0.9 1 "aarch64"
echo "findnewest Test ALARM all-NUL record" >> "$T/shadowed-packages.txt"
echo "first Test member boundary isolation" >> "$T/shadowed-packages.txt"
ARM_MIRROR="$T/arm-degraded/aarch64" expect_rc 1 "degraded ALARM DB still catches shadows" --arch aarch64 -- findnewest first foo
assert_has "[aarch64] findnewest shadows extra/findnewest with an older build: ours 0.2-1, extra 0.3-4" "all-NUL record resolved by libalpm"
assert_has "[aarch64] first shadows extra/first with an older build: ours 0.9-1, extra 1.0-1" "member boundary preserved (1.0-1, not 2.0-1)"
pass "libalpm handles ALARM all-NUL desc records and preserves tar member boundaries"

# 8. Dual-arch mirror failure preserves confirmed findings (exit 1) and exits 2 when clean
setup_clean_tree
ARM_MIRROR="$T/arm-missing/aarch64" expect_rc 2 "clean x86_64 + unreachable aarch64 mirror"
recipe lib32-bar lib32-bar 2.9 1 "x86_64"
ARM_MIRROR="$T/arm-missing/aarch64" expect_rc 1 "confirmed x86_64 finding + unreachable aarch64 mirror"
assert_has "[x86_64] lib32-bar shadows multilib/lib32-bar with an older build" "x86_64 finding preserved"
if grep -qF "shadows nothing" <<<"$OUT"; then
  fail "partial mirror failure must not produce false unused findings: $OUT"
fi

setup_clean_tree
recipe cuda cuda 13.4.2 1 "aarch64"
echo "cuda N1x CUDA carry" >> "$T/shadowed-packages.txt"
cp -a "$T/arch-mirror" "$T/arch-missing"
rm -f "$T/arch-missing/core/os/x86_64/core.db"
ARCH_MIRROR="$T/arch-missing" expect_rc 1 "confirmed aarch64 finding + unreachable x86_64 mirror"
assert_has "[aarch64] cuda shadows extra/cuda with an older build" "aarch64 finding preserved"
pass "dual-arch mirror failure exits 1 when the other arch has confirmed findings and exits 2 when clean"

# 9. Workflow invariant guard: check-shadowed.yml runs both arches on ghcr.io with --
wf="$ROOT/.github/workflows/check-shadowed.yml"
grep -qF "ghcr.io/archlinux/archlinux:base-devel" "$wf" ||
  fail "check-shadowed.yml must use ghcr.io/archlinux/archlinux:base-devel"
! grep -Eq "(^|[[:space:]])archlinux:base-devel" "$wf" ||
  fail "check-shadowed.yml must not reference Docker Hub archlinux:base-devel"
grep -qF "./bin/check-shadowed -- " "$wf" ||
  fail "check-shadowed.yml must pass -- before package names"
! grep -Eq "./bin/check-shadowed.*--arch[[:space:]]+x86_64" "$wf" ||
  fail "check-shadowed.yml must not restrict check-shadowed to x86_64 only"
pass "check-shadowed.yml enforces ghcr.io image, -- separator, and dual-arch checking"
