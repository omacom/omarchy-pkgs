#!/bin/bash
set -euo pipefail

PKG_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local label=$1 expected=$2 actual=$3
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\n--- expected ---\n%s\n--- actual ---\n%s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

# ==============================================================================
# 1. camera-sleep-hook: --collect on systemd-run and clean suspend/resume
# ==============================================================================
BIN_DIR="$TEST_ROOT/bin"
CALLS="$TEST_ROOT/calls"
mkdir -p "$BIN_DIR"

cat >"$BIN_DIR/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$CALLS"
if [[ "${FAIL_FIRST_STOP:-0}" == "1" && "$1" == "stop" && "$2" == "camera-resume.service" ]]; then
  exit 5
fi
if [[ "$1" == "stop" && "$2" == "camera-resume.service" && "${CLEAR_ACTIVE_ON_STOP:-0}" == "1" ]]; then
  rm -f "$TEST_ROOT/unit-camera-resume.active"
fi
if [[ "$1" == "reset-failed" && "$2" == "camera-resume.service" && "${CLEAR_FAILED_ON_RESET:-0}" == "1" ]]; then
  rm -f "$TEST_ROOT/unit-camera-resume.failed"
fi
exit "${SYSTEMCTL_RC:-0}"
STUB
chmod +x "$BIN_DIR/systemctl"

cat >"$BIN_DIR/systemd-run" <<'STUB'
#!/bin/bash
printf 'systemd-run %s\n' "$*" >>"$CALLS"
has_collect=0
unit=""
for arg in "$@"; do
  case "$arg" in
    --collect|-G) has_collect=1 ;;
    --unit=*) unit="${arg#--unit=}" ;;
  esac
done
state_file="$TEST_ROOT/unit-${unit}.failed"
active_file="$TEST_ROOT/unit-${unit}.active"
if [[ -f "$state_file" || -f "$active_file" ]]; then
  printf 'systemd-run-error Unit %s.service already exists\n' "$unit" >>"$CALLS"
  printf 'Failed to start transient service unit: Unit %s.service already exists.\n' "$unit" >&2
  exit 1
fi
printf 'systemd-run-accepted %s\n' "$unit" >>"$CALLS"
if [[ "${SIMULATE_RESUME_FAIL:-0}" == "1" && "$has_collect" == "0" ]]; then
  : >"$state_file"
fi
exit 0
STUB
chmod +x "$BIN_DIR/systemd-run"

# 1a. pre-suspend stops camera-resume.service and v4l2-relayd@ipu7.service (even if first stop fails)
: >"$CALLS"
PATH="$BIN_DIR:$PATH" CALLS="$CALLS" TEST_ROOT="$TEST_ROOT" FAIL_FIRST_STOP=1 \
  bash "$PKG_DIR/camera-sleep-hook" pre
grep -qx 'systemctl stop camera-resume.service' "$CALLS" || fail "pre did not stop camera-resume.service"
grep -qx 'systemctl stop v4l2-relayd@ipu7.service' "$CALLS" || fail "pre did not stop v4l2-relayd@ipu7.service"

# 1b. post-resume passes --collect, --no-block, --unit=camera-resume and survives a prior failure
# (CLEAR_FAILED_ON_RESET=0 ensures --collect itself prevents the collision rather than relying on reset-failed)
: >"$CALLS"
PATH="$BIN_DIR:$PATH" CALLS="$CALLS" TEST_ROOT="$TEST_ROOT" SIMULATE_RESUME_FAIL=1 CLEAR_FAILED_ON_RESET=0 \
  bash "$PKG_DIR/camera-sleep-hook" post
grep -qx 'systemctl reset-failed camera-resume.service' "$CALLS" || fail "post did not reset-failed camera-resume.service"
grep -qE '^systemd-run .*--collect .*--unit=camera-resume|^systemd-run .*--unit=camera-resume .*--collect' "$CALLS" \
  || fail "post systemd-run missing --collect with --unit=camera-resume"
grep -qE '^systemd-run .*--no-block' "$CALLS" || fail "post systemd-run missing --no-block"

# Second post-resume must actually be accepted by systemd-run (not masked by hook exit 0)
stderr_out=$(PATH="$BIN_DIR:$PATH" CALLS="$CALLS" TEST_ROOT="$TEST_ROOT" SIMULATE_RESUME_FAIL=0 CLEAR_FAILED_ON_RESET=0 \
  bash "$PKG_DIR/camera-sleep-hook" post 2>&1)
assert_eq "second post-resume stderr" "" "$stderr_out"
! grep -q '^systemd-run-error ' "$CALLS" || fail "second post-resume collided with existing unit"
[[ $(grep -cx 'systemd-run-accepted camera-resume' "$CALLS") == 2 ]] \
  || fail "expected 2 accepted systemd-run invocations"

# 1c. Pre-existing failed unit from before upgrade is cleared by reset-failed before systemd-run
: >"$CALLS"
: >"$TEST_ROOT/unit-camera-resume.failed"
stderr_out=$(PATH="$BIN_DIR:$PATH" CALLS="$CALLS" TEST_ROOT="$TEST_ROOT" CLEAR_FAILED_ON_RESET=1 \
  bash "$PKG_DIR/camera-sleep-hook" post 2>&1)
assert_eq "pre-upgrade failed unit stderr" "" "$stderr_out"
grep -qx 'systemd-run-accepted camera-resume' "$CALLS" \
  || fail "post-resume did not clear pre-existing failed unit"

# 1d. Still-active camera-resume.service on overlapping post is stopped before systemd-run
: >"$CALLS"
: >"$TEST_ROOT/unit-camera-resume.active"
stderr_out=$(PATH="$BIN_DIR:$PATH" CALLS="$CALLS" TEST_ROOT="$TEST_ROOT" CLEAR_ACTIVE_ON_STOP=1 \
  bash "$PKG_DIR/camera-sleep-hook" post 2>&1)
assert_eq "overlapping active unit stderr" "" "$stderr_out"
grep -qx 'systemctl stop camera-resume.service' "$CALLS" \
  || fail "post-resume did not stop still-active camera-resume.service"
grep -qx 'systemd-run-accepted camera-resume' "$CALLS" \
  || fail "post-resume collided with still-active camera-resume.service"

# ==============================================================================
# 2. intel-ipu7-camera.install: _add_pipewire_camera / _remove_pipewire_camera
# ==============================================================================
install_script=$(<"$PKG_DIR/intel-ipu7-camera.install")
install_script=${install_script//\/usr\/bin\/runuser/fixture_runuser}
# shellcheck source=/dev/null
source /dev/stdin <<<"$install_script"

fixture_runuser() {
  # Expected: --user <user> -- <cmd...>
  shift 3
  "$@"
}
id() { return 0; }

run_add() { _add_pipewire_camera "$1" "fixture-user"; }
run_remove() { _remove_pipewire_camera "$1" "fixture-user"; }

CONF="$TEST_ROOT/flags.conf"

# 2a. Empty file round-trip (sole feature added without comma, then removed completely)
: >"$CONF"
run_add "$CONF"
assert_eq "empty file add" "--enable-features=WebRtcPipeWireCamera" "$(cat "$CONF")"
run_add "$CONF"
assert_eq "empty file add idempotent" "--enable-features=WebRtcPipeWireCamera" "$(cat "$CONF")"
run_remove "$CONF"
assert_eq "empty file remove" "" "$(cat "$CONF")"
run_remove "$CONF"
assert_eq "empty file remove idempotent" "" "$(cat "$CONF")"

# 2b. Other flags only (no --enable-features=), with and without trailing newline
printf '%s\n' '--ozone-platform=wayland' >"$CONF"
run_add "$CONF"
assert_eq "other flags add" $'--ozone-platform=wayland\n--enable-features=WebRtcPipeWireCamera' "$(cat "$CONF")"
run_remove "$CONF"
assert_eq "other flags remove" "--ozone-platform=wayland" "$(cat "$CONF")"

printf '%s' '--ozone-platform=wayland' >"$CONF"
run_add "$CONF"
assert_eq "no-newline add" $'--ozone-platform=wayland\n--enable-features=WebRtcPipeWireCamera' "$(cat "$CONF")"
run_remove "$CONF"
assert_eq "no-newline remove" "--ozone-platform=wayland" "$(cat "$CONF")"

# 2c. Existing --enable-features= round-trip (non-empty and empty value)
printf '%s\n' '--enable-features=WaylandWindowDecorations' >"$CONF"
run_add "$CONF"
assert_eq "existing features add" "--enable-features=WaylandWindowDecorations,WebRtcPipeWireCamera" "$(cat "$CONF")"
run_remove "$CONF"
assert_eq "existing features remove" "--enable-features=WaylandWindowDecorations" "$(cat "$CONF")"

printf '%s\n' '--enable-features= --ozone-platform=wayland' >"$CONF"
run_add "$CONF"
assert_eq "empty enable-features add" "--enable-features=WebRtcPipeWireCamera --ozone-platform=wayland" "$(cat "$CONF")"
run_remove "$CONF"
assert_eq "empty enable-features remove" "--ozone-platform=wayland" "$(cat "$CONF")"

# 2d. First, middle, last, sole inline, and legacy PipeWireCamera layouts
printf '%s\n' '--enable-features=WebRtcPipeWireCamera,WaylandWindowDecorations' >"$CONF"
run_remove "$CONF"
assert_eq "first feature remove" "--enable-features=WaylandWindowDecorations" "$(cat "$CONF")"

printf '%s\n' '--enable-features=Foo,WebRtcPipeWireCamera,Bar' >"$CONF"
run_remove "$CONF"
assert_eq "middle feature remove" "--enable-features=Foo,Bar" "$(cat "$CONF")"

printf '%s\n' '--enable-features=Foo,WebRtcPipeWireCamera' >"$CONF"
run_remove "$CONF"
assert_eq "last feature remove" "--enable-features=Foo" "$(cat "$CONF")"

printf '%s\n' '--ozone-platform=wayland --enable-features=WebRtcPipeWireCamera --enable-wayland-ime' >"$CONF"
run_remove "$CONF"
assert_eq "sole inline feature remove" "--ozone-platform=wayland --enable-wayland-ime" "$(cat "$CONF")"

printf '%s\n' '--enable-features=WebRtcPipeWireCamera --user-agent="A  B"' >"$CONF"
run_remove "$CONF"
assert_eq "preserve spaces inside unrelated quoted arg" '--user-agent="A  B"' "$(cat "$CONF")"

# Quoted --enable-features="..." round-trip, first, last, sole
printf '%s\n' '--enable-features="Foo"' >"$CONF"
run_add "$CONF"
assert_eq "quoted features add" '--enable-features="Foo,WebRtcPipeWireCamera"' "$(cat "$CONF")"
run_add "$CONF"
assert_eq "quoted features add idempotent" '--enable-features="Foo,WebRtcPipeWireCamera"' "$(cat "$CONF")"
run_remove "$CONF"
assert_eq "quoted features remove" '--enable-features="Foo"' "$(cat "$CONF")"

printf '%s\n' '--enable-features="WebRtcPipeWireCamera,Foo"' >"$CONF"
run_remove "$CONF"
assert_eq "quoted first feature remove" '--enable-features="Foo"' "$(cat "$CONF")"

printf '%s\n' '--enable-features="WebRtcPipeWireCamera"' >"$CONF"
run_remove "$CONF"
assert_eq "quoted sole feature remove" "" "$(cat "$CONF")"

printf '%s\n' '--enable-features=PipeWireCamera' >"$CONF"
run_remove "$CONF"
assert_eq "legacy sole PipeWireCamera remove" "" "$(cat "$CONF")"

printf '%s\n' '--enable-features=PipeWireCamera,WebRtcPipeWireCamera' >"$CONF"
run_remove "$CONF"
assert_eq "legacy+current combined remove" "" "$(cat "$CONF")"

printf '%s\n' '--enable-features=PipeWireCamera,WaylandWindowDecorations' >"$CONF"
run_remove "$CONF"
assert_eq "legacy first feature remove" "--enable-features=WaylandWindowDecorations" "$(cat "$CONF")"

# 2e. Substring-similar tokens, comments, and --disable-features must stay untouched
printf '%s\n' \
  '# --enable-features=WebRtcPipeWireCamera' \
  '--disable-features=WebRtcPipeWireCamera' \
  '--enable-features=MyWebRtcPipeWireCamera,WebRtcPipeWireCamera2' >"$CONF"
run_add "$CONF"
assert_eq "similar/comment/disable add" $'# --enable-features=WebRtcPipeWireCamera\n--disable-features=WebRtcPipeWireCamera\n--enable-features=MyWebRtcPipeWireCamera,WebRtcPipeWireCamera2,WebRtcPipeWireCamera' "$(cat "$CONF")"
run_remove "$CONF"
assert_eq "similar/comment/disable remove" $'# --enable-features=WebRtcPipeWireCamera\n--disable-features=WebRtcPipeWireCamera\n--enable-features=MyWebRtcPipeWireCamera,WebRtcPipeWireCamera2' "$(cat "$CONF")"

# 2f. Comment-only --enable-features= (including indented comments) must not block add or be mutated
printf '%s\n' '# --enable-features=Foo' >"$CONF"
run_add "$CONF"
assert_eq "commented enable-features add" $'# --enable-features=Foo\n--enable-features=WebRtcPipeWireCamera' "$(cat "$CONF")"
run_remove "$CONF"
assert_eq "commented enable-features remove" "# --enable-features=Foo" "$(cat "$CONF")"

printf '%s\n' '  # --enable-features=Foo' >"$CONF"
run_add "$CONF"
assert_eq "indented comment enable-features add" $'  # --enable-features=Foo\n--enable-features=WebRtcPipeWireCamera' "$(cat "$CONF")"
run_remove "$CONF"
assert_eq "indented comment enable-features remove" "  # --enable-features=Foo" "$(cat "$CONF")"

printf '%s\n' '  # --enable-features=WebRtcPipeWireCamera' >"$CONF"
run_add "$CONF"
assert_eq "indented comment existing token add" $'  # --enable-features=WebRtcPipeWireCamera\n--enable-features=WebRtcPipeWireCamera' "$(cat "$CONF")"
run_remove "$CONF"
assert_eq "indented comment existing token remove" "  # --enable-features=WebRtcPipeWireCamera" "$(cat "$CONF")"

# 2g. Multiple browser flag files round-trip (chromium, brave, chrome)
FAKE_HOME="$TEST_ROOT/home"
mkdir -p "$FAKE_HOME/.config"
printf '%s\n' '--ozone-platform=wayland' >"$FAKE_HOME/.config/chromium-flags.conf"
printf '%s\n' '--enable-features=TouchpadOverscrollHistoryNavigation' >"$FAKE_HOME/.config/brave-flags.conf"
: >"$FAKE_HOME/.config/chrome-flags.conf"
for browser in chromium brave chrome; do
  run_add "$FAKE_HOME/.config/${browser}-flags.conf"
done
assert_eq "multi-browser chromium add" $'--ozone-platform=wayland\n--enable-features=WebRtcPipeWireCamera' "$(cat "$FAKE_HOME/.config/chromium-flags.conf")"
assert_eq "multi-browser brave add" "--enable-features=TouchpadOverscrollHistoryNavigation,WebRtcPipeWireCamera" "$(cat "$FAKE_HOME/.config/brave-flags.conf")"
assert_eq "multi-browser chrome add" "--enable-features=WebRtcPipeWireCamera" "$(cat "$FAKE_HOME/.config/chrome-flags.conf")"
for browser in chromium brave chrome; do
  run_remove "$FAKE_HOME/.config/${browser}-flags.conf"
done
assert_eq "multi-browser chromium remove" "--ozone-platform=wayland" "$(cat "$FAKE_HOME/.config/chromium-flags.conf")"
assert_eq "multi-browser brave remove" "--enable-features=TouchpadOverscrollHistoryNavigation" "$(cat "$FAKE_HOME/.config/brave-flags.conf")"
assert_eq "multi-browser chrome remove" "" "$(cat "$FAKE_HOME/.config/chrome-flags.conf")"

# 2h. Symlink must never be followed or modified
REAL_TARGET="$TEST_ROOT/real-target.conf"
SYMLINK_CONF="$TEST_ROOT/symlink.conf"
printf '%s\n' '--enable-features=WebRtcPipeWireCamera' >"$REAL_TARGET"
ln -s "$REAL_TARGET" "$SYMLINK_CONF"
run_remove "$SYMLINK_CONF"
assert_eq "symlink untouched on remove" "--enable-features=WebRtcPipeWireCamera" "$(cat "$REAL_TARGET")"

# ==============================================================================
# 3. v4l2-relayd-ipu7-override.conf & camera-wireplumber-refresh (no hardcoded UID 1000)
# ==============================================================================
OVERRIDE="$PKG_DIR/v4l2-relayd-ipu7-override.conf"
REFRESH="$PKG_DIR/camera-wireplumber-refresh"

if grep -Eq '(-M|--machine=)[[:space:]]*1000@' "$OVERRIDE"; then
  fail "v4l2-relayd-ipu7-override.conf hardcodes UID 1000"
fi
grep -qx 'ExecStartPost=-/usr/share/intel-ipu7-camera/camera-wireplumber-refresh' "$OVERRIDE" \
  || fail "v4l2-relayd-ipu7-override.conf does not invoke camera-wireplumber-refresh"
[[ -x "$REFRESH" ]] || fail "camera-wireplumber-refresh missing or not executable"
grep -q 'camera-wireplumber-refresh' "$PKG_DIR/PKGBUILD" \
  || fail "PKGBUILD does not package camera-wireplumber-refresh"

cat >"$BIN_DIR/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$CALLS"
if [[ "$1" == "list-units" ]]; then
  printf '%s\n' "${MANAGERS:-}"
  exit "${LIST_RC:-0}"
fi
if [[ "$*" == *"--machine=${FAIL_UID:-none}@.host"* ]]; then
  exit 1
fi
exit 0
STUB
chmod +x "$BIN_DIR/systemctl"

# 3a. Non-1000 single user uses --no-block try-restart
: >"$CALLS"
PATH="$BIN_DIR:$PATH" CALLS="$CALLS" CAMERA_WIREPLUMBER_DELAY=0 \
  MANAGERS="user@1001.service loaded active running User Manager for UID 1001" \
  bash "$REFRESH"
assert_eq "non-1000 user refresh" $'systemctl list-units user@*.service --state=running --no-legend --plain\nsystemctl --user --no-block --machine=1001@.host try-restart wireplumber.service' "$(cat "$CALLS")"

# 3b. Multi-user with one failing user and malformed lines
: >"$CALLS"
PATH="$BIN_DIR:$PATH" CALLS="$CALLS" CAMERA_WIREPLUMBER_DELAY=0 FAIL_UID=1000 \
  MANAGERS=$'user@1000.service loaded active running\ninvalid.service loaded active running\nuser@oops.service loaded active running\nuser@60123.service loaded active running' \
  bash "$REFRESH"
assert_eq "multi-user refresh continues after failure" $'systemctl list-units user@*.service --state=running --no-legend --plain\nsystemctl --user --no-block --machine=1000@.host try-restart wireplumber.service\nsystemctl --user --no-block --machine=60123@.host try-restart wireplumber.service' "$(cat "$CALLS")"

# 3c. No running managers and list-units failure both exit 0 cleanly
: >"$CALLS"
PATH="$BIN_DIR:$PATH" CALLS="$CALLS" CAMERA_WIREPLUMBER_DELAY=0 MANAGERS="" \
  bash "$REFRESH"
assert_eq "no managers" "systemctl list-units user@*.service --state=running --no-legend --plain" "$(cat "$CALLS")"

: >"$CALLS"
PATH="$BIN_DIR:$PATH" CALLS="$CALLS" CAMERA_WIREPLUMBER_DELAY=0 LIST_RC=1 \
  bash "$REFRESH"
assert_eq "list-units failure exits cleanly" "systemctl list-units user@*.service --state=running --no-legend --plain" "$(cat "$CALLS")"

# 3d. Dead MAINPID skips WirePlumber restart; live MAINPID proceeds
: >"$CALLS"
(exit 0) &
dead_pid=$!
wait "$dead_pid"
PATH="$BIN_DIR:$PATH" CALLS="$CALLS" CAMERA_WIREPLUMBER_DELAY=0 MAINPID="$dead_pid" \
  MANAGERS="user@1001.service loaded active running" \
  bash "$REFRESH"
assert_eq "dead MAINPID skips refresh" "" "$(cat "$CALLS")"

: >"$CALLS"
PATH="$BIN_DIR:$PATH" CALLS="$CALLS" CAMERA_WIREPLUMBER_DELAY=0 MAINPID="$$" \
  MANAGERS="user@1001.service loaded active running" \
  bash "$REFRESH"
assert_eq "live MAINPID runs refresh" $'systemctl list-units user@*.service --state=running --no-legend --plain\nsystemctl --user --no-block --machine=1001@.host try-restart wireplumber.service' "$(cat "$CALLS")"

# ==============================================================================
# 4. PKGBUILD local source checksums match pinned files
# ==============================================================================
(
  source=()
  sha256sums=()
  # shellcheck source=/dev/null
  source "$PKG_DIR/PKGBUILD"
  [[ ${#source[@]} == "${#sha256sums[@]}" ]] || fail "source/sha256sums length mismatch"
  for i in "${!source[@]}"; do
    src="${source[$i]}"
    sum="${sha256sums[$i]}"
    case "$src" in
      camera-sleep-hook|v4l2-relayd-ipu7-override.conf|camera-wireplumber-refresh)
        [[ "$sum" != "SKIP" ]] || fail "$src checksum must not be SKIP"
        actual=$(sha256sum "$PKG_DIR/$src" | awk '{print $1}')
        assert_eq "sha256sum for $src" "$actual" "$sum"
        ;;
    esac
  done
)

echo "PASS: intel-ipu7-camera sleep hook, browser flag scriptlet, WirePlumber refresh, and checksum tests"
