#!/bin/bash
# Chromium cannot reliably infer the Secret Service password-store backend
# from a Hyprland session, even when GNOME Keyring is already providing it --
# the same problem hermes-desktop hit, fixed the same way (246eea9). Left to
# its own detection the app intermittently decides no keyring is available,
# declines to persist the sign-in, and says so in a toast.
#
# Two cases are deliberately left alone: an explicit --password-store from the
# caller, and KDE, where the app already appends --password-store=kwalletd6
# itself and carries fallback logic for a KWallet with no wallet.
# CLAUDE_DESKTOP_PASSWORD_STORE overrides the choice; "none" hands the
# decision back to Electron.
set -uo pipefail

APP="/usr/lib/claude-desktop/claude-desktop"

# An explicit flag, in either --flag=value or --flag value form.
for arg in "$@"; do
  case "$arg" in
    --password-store | --password-store=*) exec "$APP" "$@" ;;
  esac
done

case "${XDG_CURRENT_DESKTOP:-}" in
  *KDE* | *Plasma* | *plasma*) exec "$APP" "$@" ;;
esac

store="${CLAUDE_DESKTOP_PASSWORD_STORE:-gnome-libsecret}"
[[ "$store" == "none" ]] && exec "$APP" "$@"

exec "$APP" --password-store="$store" "$@"
