#!/bin/bash
set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
install_src="$package_dir/facetimehd-firmware-fetcher.install"
scratch=$(mktemp -d)
child_pids=()
cleanup() {
  local pid
  for pid in "${child_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$scratch"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_scriptlet() {
  local root=$1 out=$2
  sed \
    -e "s#/run/systemd/system#$root/run/systemd/system#g" \
    -e "s#/run/lock#$root/run/lock#g" \
    -e "s#/run/facetimehd-firmware-fetcher\.removing#$root/run/facetimehd-firmware-fetcher.removing#g" \
    -e "s#/var/lib/facetimehd-firmware-fetcher#$root/var/lib/facetimehd-firmware-fetcher#g" \
    -e "s#/usr/lib/firmware/facetimehd#$root/usr/lib/firmware/facetimehd#g" \
    "$install_src" > "$out"
  ! grep -qE '(^|[ "=<>])/(run|var/lib/facetimehd-firmware-fetcher|usr/lib/firmware/facetimehd)\b' "$out" ||
    fail "rewritten test copy still references a host path"
}

# Build stub binaries for systemctl and pacman.
stubbin="$scratch/stubbin"
mkdir -p "$stubbin"
cat > "$stubbin/systemctl" <<'SH'
#!/bin/bash
set -euo pipefail
printf "%s\n" "$*" >> "$CALLS"
if [[ -n ${SYSTEMCTL_FAIL-} ]]; then
  exit 1
fi
case "$*" in
  *"is-enabled"*) [[ -n ${SERVICE_ENABLED-} ]] ;;
  *)
    if [[ -n ${SYSTEMCTL_ACTION_FAIL-} ]]; then
      exit 1
    fi
    exit 0
    ;;
esac
SH
cat > "$stubbin/pacman" <<'SH'
#!/bin/bash
set -euo pipefail
# Simulate AUR facetimehd-data owning 1571_01XX.dat only.
if [[ ${1-} == "-Qqo" && ${2-} == */1571_01XX.dat ]]; then
  echo "facetimehd-data"
  exit 0
fi
exit 1
SH
chmod 755 "$stubbin/systemctl" "$stubbin/pacman"

# Build a bin directory that provides core utils + flock + pacman, but NO systemctl.
nosystemctl="$scratch/nosystemctl"
mkdir -p "$nosystemctl"
cp "$stubbin/pacman" "$nosystemctl/pacman"
for tool in rm mkdir touch flock; do
  ln -s "$(command -v "$tool")" "$nosystemctl/$tool"
done

run_hook() {
  local script=$1 path_env=$2 hook=$3
  # shellcheck disable=SC2016
  timeout 5 env PATH="$path_env" /bin/sh -c '
    . "$1"
    "$2"
  ' sh "$script" "$hook"
}

seed_state() {
  local root=$1
  mkdir -p "$root/var/lib/facetimehd-firmware-fetcher" "$root/usr/lib/firmware/facetimehd"
  printf "firmware.bin\n1571_01XX.dat\n" > "$root/var/lib/facetimehd-firmware-fetcher/installed-files"
  echo "fw" > "$root/usr/lib/firmware/facetimehd/firmware.bin"
  echo "tmp" > "$root/usr/lib/firmware/facetimehd/.firmware.bin.new"
  echo "cal" > "$root/usr/lib/firmware/facetimehd/1571_01XX.dat"
}

# 1. pre_remove when /run/lock (and /run) do not exist (minimal chroot / container).
root1="$scratch/root-missing-run-lock"
mkdir -p "$root1"
seed_state "$root1"
make_scriptlet "$root1" "$scratch/install-1"
CALLS="$scratch/calls-1"; : > "$CALLS"; export CALLS
run_hook "$scratch/install-1" "$stubbin:/usr/bin:/bin" pre_remove ||
  fail "pre_remove must succeed when /run/lock does not exist"
[[ -d "$root1/run/lock" ]] || fail "pre_remove should create /run/lock when absent"
[[ -f "$root1/run/facetimehd-firmware-fetcher.removing" ]] || fail "pre_remove should create .removing marker"
[[ ! -e "$root1/usr/lib/firmware/facetimehd/firmware.bin" && ! -e "$root1/usr/lib/firmware/facetimehd/.firmware.bin.new" ]] ||
  fail "pre_remove should remove unowned fetched firmware and temp files"
[[ -f "$root1/usr/lib/firmware/facetimehd/1571_01XX.dat" ]] ||
  fail "pre_remove must keep files owned by another package"
[[ ! -e "$root1/var/lib/facetimehd-firmware-fetcher" ]] ||
  fail "pre_remove should remove fetcher state directory"

# 2. pre_remove when /run/lock cannot be opened (regular file blocks dir even as root):
# must fail safe (warn and preserve files rather than racing an active fetch unlocked).
root2="$scratch/root-unwritable-lock"
mkdir -p "$root2/run"
: > "$root2/run/lock"
seed_state "$root2"
make_scriptlet "$root2" "$scratch/install-2"
CALLS="$scratch/calls-2"; : > "$CALLS"; export CALLS
out2=$(run_hook "$scratch/install-2" "$stubbin:/usr/bin:/bin" pre_remove) ||
  fail "pre_remove must not abort when /run/lock is unusable"
[[ $out2 == *"Could not synchronize"* ]] || fail "pre_remove should warn when lock file cannot be opened"
[[ -f "$root2/usr/lib/firmware/facetimehd/firmware.bin" && -d "$root2/var/lib/facetimehd-firmware-fetcher" ]] ||
  fail "pre_remove must preserve files and state when it cannot synchronize via lock"

# 2b. Same unusable /run/lock without fetcher state (e.g. minimal chroot with no fetched files): quiet exit 0.
rm -rf "$root2/var/lib/facetimehd-firmware-fetcher"
out2b=$(run_hook "$scratch/install-2" "$stubbin:/usr/bin:/bin" pre_remove) ||
  fail "pre_remove must succeed quietly when /run/lock is unusable and no state exists"
[[ -z $out2b ]] || fail "pre_remove should not warn when no fetcher state exists"

# 2c. Unusable /run (cannot create .removing sentinel): warns and preserves files safely.
root2c="$scratch/root-unwritable-run"
mkdir -p "$root2c"
: > "$root2c/run"
seed_state "$root2c"
make_scriptlet "$root2c" "$scratch/install-2c"
CALLS="$scratch/calls-2c"; : > "$CALLS"; export CALLS
out2c=$(run_hook "$scratch/install-2c" "$stubbin:/usr/bin:/bin" pre_remove) ||
  fail "pre_remove must not abort when /run is unusable"
[[ $out2c == *"Could not synchronize"* ]] || fail "pre_remove should warn when .removing cannot be created"
[[ -f "$root2c/usr/lib/firmware/facetimehd/firmware.bin" && -d "$root2c/var/lib/facetimehd-firmware-fetcher" ]] ||
  fail "pre_remove must preserve files and state when .removing cannot be created"

# 2d. Non-regular lock path (FIFO inside valid /run/lock) does not hang and preserves state safely.
root2d="$scratch/root-fifo-lock"
mkdir -p "$root2d/run/lock"
mkfifo "$root2d/run/lock/facetimehd-firmware-fetcher.lock"
seed_state "$root2d"
make_scriptlet "$root2d" "$scratch/install-2d"
CALLS="$scratch/calls-2d"; : > "$CALLS"; export CALLS
out2d=$(run_hook "$scratch/install-2d" "$stubbin:/usr/bin:/bin" pre_remove) ||
  fail "pre_remove must not hang or abort on a FIFO lock path"
[[ $out2d == *"Could not synchronize"* ]] || fail "pre_remove should warn on non-regular lock path"
[[ -f "$root2d/usr/lib/firmware/facetimehd/firmware.bin" && -d "$root2d/var/lib/facetimehd-firmware-fetcher" ]] ||
  fail "pre_remove must preserve files and state when lock path is non-regular"

# 2e. Failed firmware deletion preserves installed-files manifest for retry.
root2e="$scratch/root-rm-fail"
mkdir -p "$root2e/run/lock"
seed_state "$root2e"
make_scriptlet "$root2e" "$scratch/install-2e"
rmfailbin="$scratch/rmfailbin"
mkdir -p "$rmfailbin"
cp "$stubbin/systemctl" "$stubbin/pacman" "$rmfailbin/"
cat > "$rmfailbin/rm" <<'SH'
#!/bin/bash
if [[ "$*" == */firmware.bin* ]]; then
  exit 1
fi
exec /bin/rm "$@"
SH
chmod 755 "$rmfailbin/rm"
CALLS="$scratch/calls-2e"; : > "$CALLS"; export CALLS
out2e=$(run_hook "$scratch/install-2e" "$rmfailbin:/usr/bin:/bin" pre_remove) ||
  fail "pre_remove should still return 0 when firmware deletion fails"
[[ $out2e == *"keeping"* ]] || fail "pre_remove should warn when firmware deletion fails"
[[ -f "$root2e/var/lib/facetimehd-firmware-fetcher/installed-files" ]] ||
  fail "pre_remove must preserve manifest when firmware deletion fails"

# 2f. Unreadable installed-files manifest preserves state instead of deleting it.
root2f="$scratch/root-unreadable-manifest"
mkdir -p "$root2f/run/lock"
seed_state "$root2f"
make_scriptlet "$root2f" "$scratch/install-2f"
chmod a+rx "$scratch" "$stubbin" "$root2f" "$root2f/var" "$root2f/var/lib" \
  "$root2f/usr" "$root2f/usr/lib" "$root2f/usr/lib/firmware" "$root2f/usr/lib/firmware/facetimehd"
chmod 777 "$root2f/run" "$root2f/run/lock" "$root2f/var/lib/facetimehd-firmware-fetcher"
chmod 644 "$scratch/install-2f"
chmod 000 "$root2f/var/lib/facetimehd-firmware-fetcher/installed-files"
CALLS="$scratch/calls-2f"; : > "$CALLS"; chmod 666 "$CALLS"; export CALLS
if (( EUID == 0 )) && command -v runuser >/dev/null 2>&1; then
  # shellcheck disable=SC2016
  out2f=$(runuser -u nobody -- timeout 5 env PATH="$stubbin:/usr/bin:/bin" CALLS="$CALLS" /bin/sh -c '. "$1"; pre_remove' sh "$scratch/install-2f") ||
    fail "pre_remove should return 0 when manifest cannot be read"
else
  out2f=$(run_hook "$scratch/install-2f" "$stubbin:/usr/bin:/bin" pre_remove) ||
    fail "pre_remove should return 0 when manifest cannot be read"
fi
chmod 644 "$root2f/var/lib/facetimehd-firmware-fetcher/installed-files"
[[ $out2f == *"keeping"* ]] || fail "pre_remove should warn when manifest cannot be read"
[[ -f "$root2f/var/lib/facetimehd-firmware-fetcher/installed-files" && -f "$root2f/usr/lib/firmware/facetimehd/firmware.bin" ]] ||
  fail "pre_remove must preserve manifest and firmware when manifest cannot be read"

# 3. pre_remove blocks while a fetch holds flock, keeping files intact until release, then cleans up.
root3="$scratch/root-flock-wait"
mkdir -p "$root3/run/lock"
seed_state "$root3"
make_scriptlet "$root3" "$scratch/install-3"
CALLS="$scratch/calls-3"; : > "$CALLS"; export CALLS
lock_ready="$scratch/lock-ready"
lock_release="$scratch/lock-release"
(
  flock -x 9
  : > "$lock_ready"
  while [[ ! -e $lock_release ]]; do
    sleep 0.01
  done
) 9>>"$root3/run/lock/facetimehd-firmware-fetcher.lock" &
holder=$!
child_pids+=("$holder")
for _ in $(seq 1 100); do
  [[ -e $lock_ready ]] && break
  sleep 0.01
done
[[ -e $lock_ready ]] || fail "lock holder did not acquire flock in time"
run_hook "$scratch/install-3" "$stubbin:/usr/bin:/bin" pre_remove &
remover=$!
child_pids+=("$remover")
# Wait until pre_remove has written .removing and reached flock, then verify files still survive while lock is held.
for _ in $(seq 1 50); do
  [[ -e "$root3/run/facetimehd-firmware-fetcher.removing" ]] && break
  sleep 0.01
done
sleep 0.05
kill -0 "$remover" 2>/dev/null || fail "pre_remove must stay blocked while flock is held"
[[ -f "$root3/usr/lib/firmware/facetimehd/firmware.bin" && -d "$root3/var/lib/facetimehd-firmware-fetcher" ]] ||
  fail "pre_remove must not delete files while a fetch holds the lock"
: > "$lock_release"
wait "$holder"
wait "$remover" || fail "pre_remove should succeed after lock release"
[[ ! -e "$root3/usr/lib/firmware/facetimehd/firmware.bin" && ! -e "$root3/var/lib/facetimehd-firmware-fetcher" ]] ||
  fail "pre_remove should clean up after acquiring flock"

# 4. pre_remove leaves fetched files intact when flock times out.
root4="$scratch/root-flock-timeout"
mkdir -p "$root4/run/lock"
seed_state "$root4"
make_scriptlet "$root4" "$scratch/install-4"
timeoutbin="$scratch/timeoutbin"
mkdir -p "$timeoutbin"
cp "$stubbin/systemctl" "$stubbin/pacman" "$timeoutbin/"
printf "#!/bin/bash\nexit 1\n" > "$timeoutbin/flock"
chmod 755 "$timeoutbin/flock"
CALLS="$scratch/calls-4"; : > "$CALLS"; export CALLS
out4=$(run_hook "$scratch/install-4" "$timeoutbin:/usr/bin:/bin" pre_remove) ||
  fail "pre_remove should return 0 on flock timeout"
[[ $out4 == *"still running"* ]] || fail "pre_remove should warn when fetch is still running"
[[ -f "$root4/usr/lib/firmware/facetimehd/firmware.bin" && -d "$root4/var/lib/facetimehd-firmware-fetcher" ]] ||
  fail "pre_remove must leave files and state intact on flock timeout"

# 5. Chroot (no /run/systemd/system) vs live systemd (/run/systemd/system exists).
root5="$scratch/root-chroot"
mkdir -p "$root5/run"
touch "$root5/run/facetimehd-firmware-fetcher.removing"
make_scriptlet "$root5" "$scratch/install-5"
CALLS="$scratch/calls-5"; : > "$CALLS"; export CALLS
out5=$(SERVICE_ENABLED=1 run_hook "$scratch/install-5" "$stubbin:/usr/bin:/bin" post_install) ||
  fail "post_install in chroot should succeed"
[[ ! -e "$root5/run/facetimehd-firmware-fetcher.removing" ]] ||
  fail "post_install should clear stale .removing marker"
[[ $out5 == *"once the Mac is online"* ]] || fail "post_install should note enabled service"
: > "$CALLS"
SERVICE_ENABLED=1 run_hook "$scratch/install-5" "$stubbin:/usr/bin:/bin" post_upgrade ||
  fail "post_upgrade in chroot should succeed"
! grep -q "restart" "$CALLS" || fail "post_upgrade must not restart service in chroot"
: > "$CALLS"
SERVICE_ENABLED=1 run_hook "$scratch/install-5" "$stubbin:/usr/bin:/bin" pre_remove ||
  fail "pre_remove in chroot should succeed"
grep -qx "disable facetimehd-firmware-fetcher.service" "$CALLS" ||
  fail "pre_remove in chroot should disable without --now"

# Live systemd: post_upgrade restarts, pre_remove disables --now.
mkdir -p "$root5/run/systemd/system"
: > "$CALLS"
SERVICE_ENABLED=1 run_hook "$scratch/install-5" "$stubbin:/usr/bin:/bin" post_upgrade ||
  fail "post_upgrade with live systemd should succeed"
grep -qx "restart --no-block facetimehd-firmware-fetcher.service" "$CALLS" ||
  fail "post_upgrade with live systemd should restart enabled service"
: > "$CALLS"
SERVICE_ENABLED=1 run_hook "$scratch/install-5" "$stubbin:/usr/bin:/bin" pre_remove ||
  fail "pre_remove with live systemd should succeed"
grep -qx "disable --now facetimehd-firmware-fetcher.service" "$CALLS" ||
  fail "pre_remove with live systemd should disable --now"

# 6. Missing systemctl binary & failing systemctl actions are tolerated cleanly.
root6="$scratch/root-no-systemctl"
mkdir -p "$root6"
seed_state "$root6"
make_scriptlet "$root6" "$scratch/install-6"
out6=$(run_hook "$scratch/install-6" "$nosystemctl" post_install) ||
  fail "post_install must succeed without systemctl"
[[ $out6 == *"once enabled"* ]] || fail "post_install without systemctl should print enable instructions"
run_hook "$scratch/install-6" "$nosystemctl" post_upgrade ||
  fail "post_upgrade must succeed without systemctl"
run_hook "$scratch/install-6" "$nosystemctl" pre_remove ||
  fail "pre_remove must succeed without systemctl"
[[ ! -e "$root6/usr/lib/firmware/facetimehd/firmware.bin" ]] ||
  fail "pre_remove without systemctl should still clean up firmware"

CALLS="$scratch/calls-6"; : > "$CALLS"; export CALLS
mkdir -p "$root6/run/systemd/system"
SYSTEMCTL_FAIL=1 run_hook "$scratch/install-6" "$stubbin:/usr/bin:/bin" post_install >/dev/null ||
  fail "post_install must tolerate systemctl failure"
# Exercise a failing restart after is-enabled succeeds, plus failing disable --now.
: > "$CALLS"
SERVICE_ENABLED=1 SYSTEMCTL_ACTION_FAIL=1 run_hook "$scratch/install-6" "$stubbin:/usr/bin:/bin" post_upgrade ||
  fail "post_upgrade must tolerate failing systemctl restart"
grep -qx "restart --no-block facetimehd-firmware-fetcher.service" "$CALLS" ||
  fail "post_upgrade failure test must actually invoke systemctl restart"
: > "$CALLS"
SERVICE_ENABLED=1 SYSTEMCTL_ACTION_FAIL=1 run_hook "$scratch/install-6" "$stubbin:/usr/bin:/bin" pre_remove ||
  fail "pre_remove must tolerate failing systemctl disable --now"
grep -qx "disable --now facetimehd-firmware-fetcher.service" "$CALLS" ||
  fail "pre_remove failure test must actually invoke systemctl disable --now"
grep -qx -- "--root=/ disable facetimehd-firmware-fetcher.service" "$CALLS" ||
  fail "pre_remove must fall back to systemctl --root=/ disable when disable --now fails"

echo "ok - facetimehd-firmware-fetcher"
