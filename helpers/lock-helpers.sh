# Release lock: one channel mutation at a time on this host.
#
# Everything that changes a published channel (release runs, advance, promote,
# upload-prebuilt) takes this lock, so a timer firing mid-advance or two
# operators colliding serializes instead of interleaving partial publishes.
#
# The lock lives beside the published tree (REPO_ROOT), not the checkout, so
# the primary checkout and the rc branch worktree contend on the same file.
# Reentrant across child scripts: acquiring exports OMARCHY_RELEASE_LOCK_HELD,
# and children skip acquisition when they see it (the flock fd is inherited,
# so the lock stays held for the whole tree).
#
# Two acquisition modes:
#   acquire_release_lock  waits — for humans, who want the command to run
#   try_release_lock      fails immediately — for timers, which must never
#                         queue up behind a long build and stampede when it
#                         finishes

RELEASE_LOCK_FD=9

release_lock_file() {
  echo "${REPO_ROOT:-$BUILD_ROOT/pkgs.omarchy.org}/.release.lock"
}

release_lock_holder() {
  tail -1 "$(release_lock_file)" 2>/dev/null
}

# True when the recorded holder is a live process. A holder line left behind by
# a killed run describes nothing that is still running.
release_lock_is_held() {
  local holder pid
  holder=$(release_lock_holder) || return 1
  [[ -n "$holder" ]] || return 1
  pid=$(sed -n 's/^pid \([0-9]\+\).*/\1/p' <<<"$holder")
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

_release_lock_open() {
  local lock_file
  lock_file=$(release_lock_file)
  mkdir -p "$(dirname "$lock_file")"
  eval "exec $RELEASE_LOCK_FD>>\"\$lock_file\""
}

_release_lock_record() {
  local lock_file
  lock_file=$(release_lock_file)
  # Truncate first so a crashed holder's stale line does not linger.
  : >"$lock_file"
  echo "pid $$ ($0) since $(date '+%Y-%m-%d %H:%M:%S')" >>"$lock_file"
  export OMARCHY_RELEASE_LOCK_HELD=1
}

acquire_release_lock() {
  local timeout="${1:-3600}"

  [[ -n "${OMARCHY_RELEASE_LOCK_HELD:-}" ]] && return 0

  _release_lock_open

  if ! flock -n "$RELEASE_LOCK_FD"; then
    local holder
    holder=$(release_lock_holder)
    echo "Waiting for release lock (up to ${timeout}s)${holder:+ — held by: $holder}" >&2
    if ! flock -w "$timeout" "$RELEASE_LOCK_FD"; then
      echo "Could not acquire release lock within ${timeout}s: $(release_lock_file)" >&2
      echo "If no release is actually running, remove the file and retry." >&2
      return 1
    fi
  fi

  _release_lock_record
}

# Non-blocking. Returns 1 immediately when another run holds the lock, so
# scheduled work can skip this tick instead of piling up.
try_release_lock() {
  [[ -n "${OMARCHY_RELEASE_LOCK_HELD:-}" ]] && return 0
  _release_lock_open
  flock -n "$RELEASE_LOCK_FD" || return 1
  _release_lock_record
}
