#!/bin/bash
# Run in a disposable native builder container with /package, /source and /proof mounts.
set -euo pipefail
[[ -e /.dockerenv && $EUID == 0 ]]
[[ $# == 1 && -f $1 ]]
pacman -Syu --noconfirm
pacman -U --noconfirm "$1"
systemd-sysusers /usr/lib/sysusers.d/dgx-dashboard.conf
systemd-tmpfiles --create /usr/lib/tmpfiles.d/dgx-dashboard.conf
exec dbus-run-session -- python3 /source/tests/check-dashboard-notebook.py
