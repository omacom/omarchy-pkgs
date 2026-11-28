#!/bin/bash
# Fast offline CLI and orchestration self-test for bin/check-promotion using a
# fake container engine shim.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; [[ -f $T/out ]] && cat "$T/out"; exit 1; }

FAKEBIN="$T/bin"
mkdir -p "$FAKEBIN" "$T/res"
cat << 'DOCKER_EOF' > "$FAKEBIN/docker"
#!/bin/bash
set -euo pipefail
cmd=${1:-}; shift || true
log() { printf "%s\n" "$*" >> "$FAKE_DOCKER_LOG"; }
case "$cmd" in
  info) log "info"; exit 0 ;;
  image)
    [[ ${1:-} == inspect ]] || exit 1
    log "inspect:${2:-}"
    [[ ${FAKE_MISSING_IMAGE:-} == 1 ]] && exit 1
    exit 0
    ;;
  create)
    platform="" image="" helper=""
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      case "${args[$i]}" in
        --platform=*) platform=${args[$i]} ;;
        omarchy-pkg-builder:*) image=${args[$i]} ;;
        /helpers/fast-ring-check.sh) helper="${args[*]:$i}"; break ;;
      esac
    done
    log "create:platform=$platform:image=$image:cmd=$helper"
    echo "cid-$(wc -l < "$FAKE_DOCKER_LOG" 2>/dev/null || echo 0)"
    ;;
  start)
    [[ ${FAKE_PREPARE_FAIL:-} == 1 ]] && { echo "simulated prepare failure"; exit 1; }
    exit 0
    ;;
  commit)
    log "commit:$2"
    exit 0
    ;;
  rm) exit 0 ;;
  rmi)
    log "rmi:$*"
    exit 0
    ;;
  run)
    has_promo=0 platform="" tag="" target="" url="" mode=""
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      case "${args[$i]}" in
        --platform=*) platform=${args[$i]} ;;
        -e) [[ ${args[$((i + 1))]:-} == PROMOTION=1 ]] && has_promo=1 ;;
        omarchy-promotion-check:*) tag=${args[$i]} ;;
        *"check-plan"*) mode=check-plan ;;
        *"pacman-key --verify"*"fast-ring-check.sh check "*) mode=check-verified ;;
        _)
          target=${args[$((i + 1))]:-}
          url=${args[$((i + 2))]:-}
          break
          ;;
      esac
    done
    channel=${tag##*-}
    file=${target#*=}
    log "run:mode=$mode:promo=$has_promo:platform=$platform:channel=$channel:target=$target${url:+:url=$url}"
    if [[ ${FAKE_INSPECT_FAIL:-} == "$file:$channel" ]]; then
      echo "simulated inspect crash for $file on $channel" >&2
      exit 1
    fi
    if [[ -f "$FAKE_RESULTS_DIR/$file.$channel.log" ]]; then cat "$FAKE_RESULTS_DIR/$file.$channel.log" >&2; fi
    if [[ -f "$FAKE_RESULTS_DIR/$file.$channel" ]]; then cat "$FAKE_RESULTS_DIR/$file.$channel"; fi
    ;;
  *)
    echo "unexpected fake docker command: $cmd $*" >&2
    exit 1
    ;;
esac
DOCKER_EOF
chmod +x "$FAKEBIN/docker"

run_cp() {
  local -a env_args=()
  while [[ ${1:-} == *=* ]]; do env_args+=("$1"); shift; done
  env "${env_args[@]}" PATH="$FAKEBIN:$PATH" \
    FAKE_DOCKER_LOG="$T/docker.log" FAKE_RESULTS_DIR="$T/res" \
    "$ROOT/bin/check-promotion" "$@" >"$T/out" 2>&1
}

expect_rc() {
  local want=$1 desc=$2 rc=0; shift 2
  : > "$T/docker.log"
  if (( want == 2 )); then
    env -u CONTAINER_ENGINE PATH="$FAKEBIN:$PATH" \
      FAKE_DOCKER_LOG="$T/docker.log" FAKE_RESULTS_DIR="$T/res" \
      "$ROOT/bin/check-promotion" "$@" >"$T/out" 2>&1 || rc=$?
  else
    run_cp CONTAINER_ENGINE=docker "$@" || rc=$?
  fi
  (( rc == want )) || fail "$desc (wanted rc=$want, got rc=$rc)"
  if (( want == 2 )) && [[ -s $T/docker.log ]]; then
    fail "$desc touched docker: $(cat "$T/docker.log")"
  fi
  pass "$desc"
}

# --- CLI & plan validation (must fail fast with exit 2 and ZERO docker calls) ---
printf "alpha\talpha\talpha-1.0-1-x86_64.pkg.tar.zst\n" > "$T/valid.plan"
: > "$T/empty.plan"
expect_rc 2 "unknown long option exits 2" --bogus --arch x86_64 --from edge --to rc "$T/valid.plan"
expect_rc 2 "unknown short option exits 2" -x --arch x86_64 --from edge --to rc "$T/valid.plan"
expect_rc 2 "bare --arch with no value exits 2" --arch
expect_rc 2 "missing --arch exits 2" --from edge --to rc "$T/valid.plan"
expect_rc 2 "invalid --arch exits 2" --arch sparc --from edge --to rc "$T/valid.plan"
expect_rc 2 "multi-word --arch exits 2" --arch "x86_64 aarch64" --from edge --to rc "$T/valid.plan"
expect_rc 2 "same --from and --to exits 2" --arch x86_64 --from rc --to rc "$T/valid.plan"
: > "$T/docker.log"; rc=0
env -u CONTAINER_ENGINE FROM=edge TO=rc PATH="$FAKEBIN:$PATH" FAKE_DOCKER_LOG="$T/docker.log" FAKE_RESULTS_DIR="$T/res" \
  "$ROOT/bin/check-promotion" --arch x86_64 "$T/valid.plan" >"$T/out" 2>&1 || rc=$?
(( rc == 2 )) && [[ ! -s $T/docker.log ]] && pass "inherited FROM/TO env vars do not satisfy omitted flags" || fail "env FROM/TO rc=$rc"
: > "$T/docker.log"; rc=0
env -u CONTAINER_ENGINE PATH="$FAKEBIN:$PATH" FAKE_DOCKER_LOG="$T/docker.log" FAKE_RESULTS_DIR="$T/res" \
  "$ROOT/bin/check-promotion" --help >"$T/out" 2>&1 || rc=$?
(( rc == 0 )) && [[ ! -s $T/docker.log ]] && grep -q "Usage: bin/check-promotion" "$T/out" && pass "--help exits 0 with zero docker calls" || fail "--help rc=$rc"
expect_rc 2 "backwards promotion rc -> edge exits 2" --arch x86_64 --from rc --to edge "$T/valid.plan"
expect_rc 2 "backwards promotion stable -> rc exits 2" --arch x86_64 --from stable --to rc "$T/valid.plan"
for bad_jobs in 0 18446744073709551616; do
  : > "$T/docker.log"; rc=0
  env -u CONTAINER_ENGINE CHECK_PROMOTION_JOBS="$bad_jobs" PATH="$FAKEBIN:$PATH" \
    FAKE_DOCKER_LOG="$T/docker.log" FAKE_RESULTS_DIR="$T/res" \
    "$ROOT/bin/check-promotion" --arch x86_64 --from edge --to rc "$T/valid.plan" >"$T/out" 2>&1 || rc=$?
  (( rc == 2 )) && [[ ! -s $T/docker.log ]] && pass "CHECK_PROMOTION_JOBS=$bad_jobs exits 2 with zero docker calls" || fail "JOBS=$bad_jobs rc=$rc"
done
expect_rc 2 "empty plan exits 2" --arch x86_64 --from edge --to rc "$T/empty.plan"
expect_rc 2 "missing plan file exits 2" --arch x86_64 --from edge --to rc "$T/no-such.plan"
expect_rc 2 "directory as plan exits 2" --arch x86_64 --from edge --to rc "$T"
expect_rc 2 "extra positional arg exits 2" --arch x86_64 --from edge --to rc "$T/valid.plan" extra

# Table-driven malformed plan line checks (all must exit 2 with zero docker calls).
bad_plans=(
  "duplicate pkgname|alpha\talpha\talpha-1.0-1-x86_64.pkg.tar.zst\nalpha\talpha\talpha-1.0-2-x86_64.pkg.tar.zst\n"
  "extra tab column|alpha\talpha\talpha-1.0-1-x86_64.pkg.tar.zst\textra\n"
  "adjacent tabs (empty field)|alpha\t\talpha\talpha-1.0-1-x86_64.pkg.tar.zst\n"
  "trailing tab (empty 4th field)|alpha\talpha\talpha-1.0-1-x86_64.pkg.tar.zst\t\n"
  "path-traversal pkgname|alpha\t../escape\talpha-1.0-1-x86_64.pkg.tar.zst\n"
  "dotdot pkgname|alpha\t..\talpha-1.0-1-x86_64.pkg.tar.zst\n"
  "dotdot pkgbase|..\talpha\talpha-1.0-1-x86_64.pkg.tar.zst\n"
  "slash in filename|alpha\talpha\tsub/alpha-1.0-1-x86_64.pkg.tar.zst\n"
  "dot filename|alpha\talpha\t.\n"
  "dotdot filename|alpha\talpha\t..\n"
  "non-archive filename|alpha\talpha\tgarbage\n"
  "wrong-arch filename|alpha\talpha\talpha-1.0-1-aarch64.pkg.tar.zst\n"
  "signature suffix .zst.sig|alpha\talpha\talpha-1.0-1-x86_64.pkg.tar.zst.sig\n"
  "signature ext .pkg.tar.sig|alpha\talpha\talpha-1.0-1-x86_64.pkg.tar.sig\n"
  "mismatched pkgname filename|alpha\talpha\tother-1.0-1-x86_64.pkg.tar.zst\n"
  "prefix-mismatched filename|alpha\talpha\talpha-tools-1.0-1-x86_64.pkg.tar.zst\n"
  "empty version/release filename|alpha\talpha\talpha---x86_64.pkg.tar.zst\n"
  "whitespace in version|alpha\talpha\talpha-1.0 bad-1-x86_64.pkg.tar.zst\n"
  "multi-dot pkgrel|alpha\talpha\talpha-1.0-1.2.3-x86_64.pkg.tar.zst\n"
  "control char in version|alpha\talpha\talpha-1.0\rrc1-1-x86_64.pkg.tar.zst\n"
  "NUL byte in plan|alpha\tal\0pha\talpha-1.0-1-x86_64.pkg.tar.zst\n"
)
for spec in "${bad_plans[@]}"; do
  desc=${spec%%|*}
  body=${spec#*|}
  # shellcheck disable=SC2059
  printf "%b" "$body" > "$T/bad.plan"
  expect_rc 2 "malformed plan ($desc) exits 2" --arch x86_64 --from edge --to rc "$T/bad.plan"
done

# Dash-prefixed relative plan path after -- (including literal "-") must work safely.
cp "$T/valid.plan" "$T/-"
: > "$T/docker.log"
(cd "$T" && run_cp CONTAINER_ENGINE=docker --arch x86_64 --from edge --to rc -- -) || fail "dash plan path failed"
grep -q "run:mode=check-plan:promo=1:platform=--platform=linux/amd64:channel=rc:target=alpha=alpha-1.0-1-x86_64.pkg.tar.zst" "$T/docker.log" \
  && pass "dash-named plan file after -- is normalized and checked safely" || fail "dash plan log: $(cat "$T/docker.log")"

# Valid plan with neither docker nor podman on PATH reports missing engine cleanly (no unbound var).
mkdir -p "$T/no-engine-bin"
for tool in bash env cat cmp mktemp rm tr jq grep awk sed tail dirname realpath; do
  p_tool=$(command -v "$tool" 2>/dev/null) && ln -sf "$p_tool" "$T/no-engine-bin/$tool" || true
done
rc=0
env -u CONTAINER_ENGINE PATH="$T/no-engine-bin" "$ROOT/bin/check-promotion" --arch x86_64 --from edge --to rc "$T/valid.plan" >"$T/out" 2>&1 || rc=$?
(( rc == 1 )) && grep -q "No working container engine found" "$T/out" && ! grep -q "unbound variable" "$T/out" \
  && pass "missing container engine reports error cleanly without unbound variable" || fail "no-engine rc=$rc"

expect_rc 1 "missing builder image exits 1" FAKE_MISSING_IMAGE=1 --arch x86_64 --from edge --to rc "$T/valid.plan"
grep -q "Builder image omarchy-pkg-builder:latest-x86_64-edge is missing" "$T/out" \
  && pass "missing builder image names the expected image" || fail "missing image message"

expect_rc 1 "prepare failure exits 1" FAKE_PREPARE_FAIL=1 --arch x86_64 --from edge --to rc "$T/valid.plan"
grep -q "Could not prepare rc (x86_64)" "$T/out" \
  && pass "prepare failure reports channel and exits 1" || fail "prepare fail output"

# --- aarch64 split-package plan with -any artifact and NO trailing newline ---
printf "split\tsplit-bin\tsplit-bin-1.0-1-aarch64.pkg.tar.zst\nsplit\tsplit-data\tsplit-data-1.0-1-any.pkg.tar.zst" > "$T/arm-no-nl.plan"
: > "$T/docker.log"
run_cp CONTAINER_ENGINE=docker --arch aarch64 --from edge --to rc "$T/arm-no-nl.plan" || fail "aarch64 no-newline plan failed"
grep -q "inspect:omarchy-pkg-builder:latest-aarch64-edge" "$T/docker.log" \
  && grep -q "create:platform=--platform=linux/arm64:image=omarchy-pkg-builder:latest-aarch64-edge:cmd=/helpers/fast-ring-check.sh prepare-view rc edge aarch64 split-bin split-data" "$T/docker.log" \
  && grep -q "run:mode=check-plan:promo=1:platform=--platform=linux/arm64:channel=rc:target=split-bin=split-bin-1.0-1-aarch64.pkg.tar.zst" "$T/docker.log" \
  && grep -q "run:mode=check-plan:promo=1:platform=--platform=linux/arm64:channel=rc:target=split-data=split-data-1.0-1-any.pkg.tar.zst" "$T/docker.log" \
  && grep -qE "^rmi:omarchy-promotion-check:aarch64-[0-9]+-edge omarchy-promotion-check:aarch64-[0-9]+-rc$" "$T/docker.log" \
  && pass "aarch64 plan without trailing newline checks both split targets (including -any) and cleans up both tags" || fail "arm64 log: $(cat "$T/docker.log")"

# --- uppercase pkgbase, MyApp-debug, epoch + ~rc1 version, and edge -> stable ---
printf "MyApp\tmy-app\tmy-app-1.0-1-x86_64.pkg.tar.zst\n" > "$T/hyphen.plan"
printf "MyApp\tmy-app\tmy-app-2:1.0~rc1-1-x86_64.pkg.tar.zst\nMyApp\tMyApp-debug\tMyApp-debug-2:1.0@rc1-1-x86_64.pkg.tar.zst\n" > "$T/upper-debug.plan"
expect_rc 0 "uppercase pkgbase, MyApp-debug, and epoch+~rc1 filename pass edge -> stable" --arch x86_64 --from edge --to stable "$T/upper-debug.plan"
[[ $(grep -c "^run:mode=check-plan:promo=1:platform=--platform=linux/amd64:channel=stable:" "$T/docker.log") -eq 2 ]] \
  && grep -q "target=my-app=my-app-2:1.0~rc1-1-x86_64.pkg.tar.zst$" "$T/docker.log" \
  && grep -q "target=MyApp-debug=MyApp-debug-2:1.0@rc1-1-x86_64.pkg.tar.zst$" "$T/docker.log" \
  && pass "edge -> stable inspected both uppercase/debug/~rc1 artifacts exactly once" || fail "upper-debug log: $(cat "$T/docker.log")"

# --- package named prepare-rc.log must not collide with prepare log path ---
printf "prepare-rc.log\tprepare-rc.log\tprepare-rc.log-1.0-1-x86_64.pkg.tar.zst\n" > "$T/prepare-log-name.plan"
expect_rc 0 "package named prepare-rc.log does not collide with prepare log" --arch x86_64 --from edge --to rc "$T/prepare-log-name.plan"
[[ $(grep -c "^run:mode=check-plan:promo=1:platform=--platform=linux/amd64:channel=rc:target=prepare-rc.log=prepare-rc.log-1.0-1-x86_64.pkg.tar.zst$" "$T/docker.log") -eq 1 ]] \
  && pass "prepare-rc.log artifact inspected once without colliding with prepare log" || fail "prepare-log-name log: $(cat "$T/docker.log")"

# --- edge -> rc: destination-only link error fails; shared edge link error is excused ---
alpha_file="alpha-1.0-1-x86_64.pkg.tar.zst"
printf "link\t/usr/bin/alpha\tlibfoo.so.2 => not found\n" > "$T/res/$alpha_file.rc"
: > "$T/res/$alpha_file.edge"
expect_rc 1 "edge -> rc fails on a destination-only link problem" --arch x86_64 --from edge --to rc "$T/valid.plan"
grep -q "libfoo.so.2 => not found" "$T/out" || fail "link error output"

cp "$T/res/$alpha_file.rc" "$T/res/$alpha_file.edge"
expect_rc 0 "edge -> rc excuses a link problem that edge shares" --arch x86_64 --from edge --to rc "$T/valid.plan"

# --- rc -> stable (hyphenated pkg): link problem must exist on BOTH rc AND edge ---
rm -f "$T/res"/*
hyphen_file="my-app-1.0-1-x86_64.pkg.tar.zst"
printf "link\t/usr/bin/my-app\tlibbar.so.1 => not found\n" > "$T/res/$hyphen_file.stable"
printf "link\t/usr/bin/my-app\tlibbar.so.1 => not found\n" > "$T/res/$hyphen_file.rc"
: > "$T/res/$hyphen_file.edge"
expect_rc 1 "rc -> stable refuses a link problem absent from edge" --arch x86_64 --from rc --to stable "$T/hyphen.plan"
grep -q "libbar.so.1 => not found" "$T/out" || fail "rc->stable unexcused output"
grep -q "create:platform=--platform=linux/amd64:image=omarchy-pkg-builder:latest-x86_64-edge:cmd=/helpers/fast-ring-check.sh prepare edge x86_64$" "$T/docker.log" \
  && grep -q "run:mode=check-verified:promo=1:platform=--platform=linux/amd64:channel=edge:target=$hyphen_file:url=https://pkgs.omarchy.org/rc/x86_64/$hyphen_file" "$T/docker.log" \
  && grep -qE "^rmi:omarchy-promotion-check:x86_64-[0-9]+-rc omarchy-promotion-check:x86_64-[0-9]+-stable omarchy-promotion-check:x86_64-[0-9]+-edge$" "$T/docker.log" \
  && pass "rc -> stable prepares clean edge baseline, fetches RC file for edge check, and cleans up all 3 tags" || fail "rc->stable log: $(cat "$T/docker.log")"

cp "$T/res/$hyphen_file.rc" "$T/res/$hyphen_file.edge"
expect_rc 0 "rc -> stable excuses a link problem shared by both rc and edge" --arch x86_64 --from rc --to stable "$T/hyphen.plan"

: > "$T/res/$hyphen_file.rc"
expect_rc 1 "rc -> stable refuses a link problem absent from rc even when edge has it" --arch x86_64 --from rc --to stable "$T/hyphen.plan"
grep -q "libbar.so.1 => not found" "$T/out" || fail "rc-clean unexcused output"

# --- Arch-valid version characters (:, +, ~, @) pass validation and URL-encode in edge fetch ---
rm -f "$T/res"/*
url_file="alpha-2:1.0+git~rc1@1-1-x86_64.pkg.tar.zst"
printf "alpha\talpha\t%s\n" "$url_file" > "$T/urlchars.plan"
printf "link\t/usr/bin/alpha\tliburl.so.1 => not found\n" > "$T/res/$url_file.stable"
cp "$T/res/$url_file.stable" "$T/res/$url_file.rc"
cp "$T/res/$url_file.stable" "$T/res/$url_file.edge"
expect_rc 0 "Arch-valid version chars (:, +, ~, @) pass validation and edge baseline check" --arch x86_64 --from rc --to stable "$T/urlchars.plan"
grep -Fq "run:mode=check-verified:promo=1:platform=--platform=linux/amd64:channel=edge:target=$url_file:url=https://pkgs.omarchy.org/rc/x86_64/alpha-2%3A1.0%2Bgit~rc1%401-1-x86_64.pkg.tar.zst" "$T/docker.log" \
  && pass "edge baseline curl URL percent-encodes :, +, and @ while keeping ~" || fail "urlchars log: $(cat "$T/docker.log")"

# --- shared link + shared rule: baseline runs, link is excused, rule still fails ---
rm -f "$T/res"/*
printf "link\t/usr/bin/alpha\tlibopt.so.1 => not found\nrule\t-\tthe packages cannot be installed on this channel\n" > "$T/res/$alpha_file.rc"
cp "$T/res/$alpha_file.rc" "$T/res/$alpha_file.edge"
printf "error: failed to prepare transaction\n" > "$T/res/$alpha_file.rc.log"
expect_rc 1 "rule failure fails even when baseline runs and matches both link and rule" --arch x86_64 --from edge --to rc "$T/valid.plan"
grep -q "channel=edge" "$T/docker.log" && ! grep -q "libopt.so.1" "$T/out" && grep -q "failed to prepare transaction" "$T/out" \
  && pass "baseline excuses shared link while rule still fails with pacman diagnostics" || fail "rule+link output"

# --- inspect crash fails the check ---
rm -f "$T/res"/*
expect_rc 1 "container failure during inspect exits 1" FAKE_INSPECT_FAIL="$alpha_file:rc" --arch x86_64 --from edge --to rc "$T/valid.plan"
grep -q "the check itself failed" "$T/out" \
  && pass "container failure during inspect reports check failure" || fail "inspect fail output"
