#!/bin/bash

check_packaged_daemon_stopped() {
  proc_root=${1:-/proc}
  if [[ ! -d "$proc_root" ]]; then
    printf 'Cannot safely verify running processes: %s is not available.\n' "$proc_root" >&2
    return 1
  fi
  for process in "$proc_root"/[0-9]*; do
    [[ -L "$process/exe" ]] || continue
    executable=$(readlink "$process/exe" 2>/dev/null) || continue
    case "$executable" in
      /usr/bin/klicky|"/usr/bin/klicky (deleted)")
        printf 'Cannot upgrade or remove Klicky while packaged daemon PID %s is running. Stop the user service, then retry.\n' "${process##*/}" >&2
        return 1
        ;;
    esac
  done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  check_packaged_daemon_stopped
fi
