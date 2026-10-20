#!/bin/bash
# Electron picks its safeStorage backend from the desktop it detects. On
# Hyprland it detects neither GNOME nor KDE, so it falls back to basic_text
# and stores tokens unencrypted, and the app then reports that no system
# keyring is available even though one is running. The launcher asks for the
# keyring explicitly, unless the user picked a backend themselves.
set -euo pipefail

fail() {
  echo "not ok - $1" >&2
  [[ -n ${2:-} ]] && echo "$2" >&2
  exit 1
}

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

home="$scratch/home"
config="$home/.config"
mkdir -p "$config"

# The launcher runs the application by absolute path, so the test replaces
# that path with a stub that records the arguments it was given.
cat >"$scratch/claude-desktop" <<'SH'
#!/bin/bash
printf '%s\n' "$@" >"$CLAUDE_ARGS"
SH
chmod +x "$scratch/claude-desktop"

sed "s|/usr/lib/claude-desktop/claude-desktop|$scratch/claude-desktop|" \
  "$package_dir/claude-desktop-launcher.sh" >"$scratch/launcher"
chmod +x "$scratch/launcher"

export CLAUDE_ARGS="$scratch/args"
export HOME="$home"
unset XDG_CONFIG_HOME

run_launcher() {
  "$scratch/launcher" "$@"
  cat "$CLAUDE_ARGS"
}

flags=$(run_launcher)
grep -qx -- '--password-store=gnome-libsecret' <<<"$flags" ||
  fail "the launcher asks for the keyring backend" "$flags"
echo "ok - the launcher asks for the keyring backend"

# A backend the user chose wins over the one the launcher defaults to.
printf -- '--password-store=basic\n' >"$config/claude-desktop-flags.conf"
flags=$(run_launcher)
grep -qx -- '--password-store=gnome-libsecret' <<<"$flags" &&
  fail "the launcher's default does not override the user's backend" "$flags"
echo "ok - the launcher's default does not override the user's backend"

rm -f "$config/claude-desktop-flags.conf"
flags=$(run_launcher --password-store=basic)
grep -qx -- '--password-store=gnome-libsecret' <<<"$flags" &&
  fail "the launcher's default does not override a backend passed as an argument" "$flags"
echo "ok - the launcher's default does not override a backend passed as an argument"

# A backend the user chose is the only one that reaches the application: the
# launcher drops its default rather than passing both.
printf -- '--password-store=basic\n' >"$config/claude-desktop-flags.conf"
flags=$(run_launcher)
[[ $(grep -c -- '--password-store=' <<<"$flags") == 1 ]] ||
  fail "the user's backend is the only one that reaches the application" "$flags"
grep -qx -- '--password-store=basic' <<<"$flags" ||
  fail "the user's backend reaches the application" "$flags"
echo "ok - the user's backend is the only one that reaches the application"
