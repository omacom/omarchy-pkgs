#!/bin/bash
set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
install_file="$package_dir/nvidia-580xx-utils.install"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Build a minimal PATH directory without systemctl for missing-systemd tests.
minbin="$scratch/minbin"
mkdir -p "$minbin"
cat > "$minbin/vercmp" <<'SH'
#!/bin/bash
printf "%s\n" "${FAKE_VERCMP:-0}"
SH
chmod 755 "$minbin/vercmp"

# Build a stub bin directory with a realistic systemctl that mimics Arch
# systemd behavior (src/shared/install.c): enable requires the unit file;
# disable removes leftover symlinks even when the unit file is gone, but
# still exits non-zero if the unit file does not exist.
stubbin="$scratch/stubbin"
mkdir -p "$stubbin"
cp "$minbin/vercmp" "$stubbin/vercmp"
cat > "$stubbin/systemctl" <<'SH'
#!/bin/bash
set -euo pipefail
printf "%s\n" "$*" >> "$CALLS"

if [[ -n ${SYSTEMCTL_FAIL-} ]]; then
  echo "System has not been booted with systemd as init system (PID 1)." >&2
  exit 1
fi

cmd=""
args=()
for arg in "$@"; do
  case "$arg" in
    --quiet|-q|--no-reload) ;;
    *)
      if [[ -z $cmd ]]; then
        cmd=$arg
      else
        args+=("$arg")
      fi
      ;;
  esac
done

case "$cmd" in
  enable)
    # Match systemd install.c: validate every unit in the batch before creating symlinks.
    for u in "${args[@]}"; do
      u=${u%.service}
      if [[ ${MASKED_UNIT-} == "$u" ]]; then
        echo "Unit $u.service is masked." >&2
        exit 1
      fi
      if [[ ! -f "$UNITS/$u.service" ]]; then
        echo "Unit file $u.service does not exist." >&2
        exit 1
      fi
    done
    for u in "${args[@]}"; do
      touch "$ENABLED/${u%.service}"
    done
    exit 0
    ;;
  disable)
    rc=0
    for u in "${args[@]}"; do
      u=${u%.service}
      rm -f "$ENABLED/$u"
      if [[ ! -f "$UNITS/$u.service" ]]; then
        echo "Failed to disable unit: Unit $u.service does not exist" >&2
        rc=1
        continue
      fi
    done
    exit "$rc"
    ;;
  is-enabled)
    u=${args[0]%.service}
    if [[ ! -f "$UNITS/$u.service" ]]; then
      exit 4
    fi
    [[ -f "$ENABLED/$u" ]]
    ;;
  *)
    echo "unexpected systemctl command: $*" >&2
    exit 2
    ;;
esac
SH
chmod 755 "$stubbin/systemctl"

run_hook() {
  local path_env=$1
  shift
  local hook=$1
  shift
  PATH="$path_env" /bin/sh -c '
    . "$1"
    hook=$2
    shift 2
    if command -v "$hook" >/dev/null 2>&1; then
      "$hook" "$@"
    fi
  ' sh "$install_file" "$hook" "$@"
}

setup_units() {
  UNITS="$scratch/units-$1"
  ENABLED="$scratch/enabled-$1"
  CALLS="$scratch/calls-$1"
  mkdir -p "$UNITS" "$ENABLED"
  : > "$CALLS"
  export UNITS ENABLED CALLS
  for u in nvidia-resume nvidia-hibernate nvidia-suspend; do
    : > "$UNITS/$u.service"
  done
}

# 1. Normal install -> pre_remove (units present) -> pacman deletes units -> post_remove.
setup_units lifecycle
run_hook "$stubbin:/usr/bin:/bin" post_install "580.196.11-2" || fail "post_install should succeed"
for u in nvidia-resume nvidia-hibernate nvidia-suspend; do
  [[ -f "$ENABLED/$u" ]] || fail "post_install should enable $u"
done

run_hook "$stubbin:/usr/bin:/bin" pre_remove "580.196.11-2" || fail "pre_remove should succeed while units exist"
for u in nvidia-resume nvidia-hibernate nvidia-suspend; do
  [[ ! -e "$ENABLED/$u" ]] || fail "pre_remove should disable $u before unit deletion"
done

: > "$CALLS"
rm -f "$UNITS"/*.service
run_hook "$stubbin:/usr/bin:/bin" post_remove "580.196.11-2" || fail "post_remove must not fail after pacman deletes unit files"
[[ ! -s "$CALLS" ]] || fail "post_remove must not invoke systemctl after unit deletion"

# 2. Dangling enablement symlink with missing unit file is still removed cleanly.
setup_units dangling-symlink
ln -s "$UNITS/nvidia-resume.service" "$ENABLED/nvidia-resume"
rm -f "$UNITS/nvidia-resume.service"
[[ -L "$ENABLED/nvidia-resume" && ! -e "$ENABLED/nvidia-resume" ]] || fail "fixture should be a real dangling symlink"
run_hook "$stubbin:/usr/bin:/bin" pre_remove "580.196.11-2" || fail "pre_remove must tolerate missing unit file"
[[ ! -L "$ENABLED/nvidia-resume" && ! -e "$ENABLED/nvidia-resume" ]] || fail "pre_remove should remove dangling symlink even when unit file is missing"

# 3. Minimal chroot without systemctl on PATH.
setup_units no-systemctl
run_hook "$minbin" post_install "580.196.11-2" || fail "post_install must succeed without systemctl"
FAKE_VERCMP=-1 run_hook "$minbin" post_upgrade "580.196.11-2" "560.35.03-1" || fail "post_upgrade must succeed without systemctl"
run_hook "$minbin" pre_remove "580.196.11-2" || fail "pre_remove must succeed without systemctl"

# 4. Systemd unavailable / systemctl exits non-zero (chroot/container failure).
setup_units systemctl-fail
SYSTEMCTL_FAIL=1 run_hook "$stubbin:/usr/bin:/bin" post_install "580.196.11-2" || fail "post_install must tolerate systemctl failure"
SYSTEMCTL_FAIL=1 FAKE_VERCMP=-1 run_hook "$stubbin:/usr/bin:/bin" post_upgrade "580.196.11-2" "560.35.03-1" >/dev/null || fail "post_upgrade must tolerate systemctl failure"
SYSTEMCTL_FAIL=1 run_hook "$stubbin:/usr/bin:/bin" pre_remove "580.196.11-2" || fail "pre_remove must tolerate systemctl failure"

# 5. One masked unit in post_install does not block enabling the remaining units.
setup_units masked-unit
MASKED_UNIT=nvidia-hibernate run_hook "$stubbin:/usr/bin:/bin" post_install "580.196.11-2" || fail "post_install must succeed when one unit is masked"
[[ -f "$ENABLED/nvidia-resume" && ! -e "$ENABLED/nvidia-hibernate" && -f "$ENABLED/nvidia-suspend" ]] ||
  fail "post_install should still enable unmasked units when one is masked"

# 6. post_upgrade respects the 560.35.03-16 threshold and skips already-enabled units.
setup_units upgrade-old
touch "$ENABLED/nvidia-resume"
FAKE_VERCMP=-1 run_hook "$stubbin:/usr/bin:/bin" post_upgrade "580.196.11-2" "560.35.03-1" >/dev/null ||
  fail "post_upgrade from < 560.35.03-16 should succeed"
for u in nvidia-resume nvidia-hibernate nvidia-suspend; do
  [[ -f "$ENABLED/$u" ]] || fail "post_upgrade from < 560.35.03-16 should enable $u"
done
! grep -qx "enable nvidia-resume" "$CALLS" ||
  fail "post_upgrade should skip enabling already-enabled nvidia-resume"

setup_units upgrade-eq
FAKE_VERCMP=0 run_hook "$stubbin:/usr/bin:/bin" post_upgrade "580.196.11-2" "560.35.03-16" >/dev/null ||
  fail "post_upgrade from == 560.35.03-16 should succeed"
[[ ! -s "$CALLS" ]] || fail "post_upgrade from == 560.35.03-16 should not touch services"

setup_units upgrade-new
FAKE_VERCMP=1 run_hook "$stubbin:/usr/bin:/bin" post_upgrade "580.196.11-2" "580.196.11-1" >/dev/null ||
  fail "post_upgrade from > 560.35.03-16 should succeed"
[[ ! -s "$CALLS" ]] || fail "post_upgrade from > 560.35.03-16 should not touch services"

echo "ok - nvidia-580xx-utils"
