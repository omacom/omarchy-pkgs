#!/bin/bash
# The launcher decides which safeStorage backend the application uses; see the
# comment in claude-desktop-launcher.sh for why it asks for the keyring.
set -euo pipefail

fail() {
  echo "not ok - $1" >&2
  [[ -n ${2:-} ]] && echo "$2" >&2
  exit 1
}

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
launcher_checksum=$(grep '^sha256sums=' "$package_dir/PKGBUILD" | cut -d"'" -f2)
[[ "$launcher_checksum" =~ ^[[:xdigit:]]{64}$ ]] ||
  fail "the PKGBUILD declares the launcher checksum"
printf '%s  %s\n' "$launcher_checksum" "$package_dir/claude-desktop-launcher.sh" |
  sha256sum --check || fail "the launcher matches the PKGBUILD checksum"
echo "ok - the launcher matches the PKGBUILD checksum"

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

# The stub only stands in for the application when the path was replaced. A
# launcher that installs somewhere else would start the real application, so
# the substitution has to have taken effect before the launcher runs.
grep -q -- "$scratch/claude-desktop" "$scratch/launcher" ||
  fail "the launcher runs the application from the path the test replaces"

export CLAUDE_ARGS="$scratch/args"
export HOME="$home"
export XDG_SESSION_TYPE=wayland
export XDG_CURRENT_DESKTOP=Hyprland
unset XDG_CONFIG_HOME WAYLAND_DISPLAY

run_launcher() {
  timeout 10 "$scratch/launcher" "$@" || fail "the launcher failed" "$*"
  cat "$CLAUDE_ARGS"
}

backend_flags() {
  grep -c -- '--password-store' || true
}

# The launcher asks for the keyring backend, and asks for it once.
flags=$(run_launcher)
[[ $(backend_flags <<<"$flags") == 1 ]] ||
  fail "the launcher asks for the keyring backend exactly once" "$flags"
grep -qx -- '--password-store=gnome-libsecret' <<<"$flags" ||
  fail "the launcher asks for the keyring backend" "$flags"
echo "ok - the launcher asks for the keyring backend"

# A backend the user chose is the only one that reaches the application: the
# launcher drops its default rather than passing both.
printf -- '--password-store=basic\n' >"$config/claude-desktop-flags.conf"
flags=$(run_launcher)
[[ $(backend_flags <<<"$flags") == 1 ]] ||
  fail "the user's backend is the only one that reaches the application" "$flags"
grep -qx -- '--password-store=basic' <<<"$flags" ||
  fail "the user's backend reaches the application" "$flags"
echo "ok - the user's backend is the only one that reaches the application"

# The same holds for a backend passed as an argument.
rm -f "$config/claude-desktop-flags.conf"
flags=$(run_launcher --password-store=basic)
[[ $(backend_flags <<<"$flags") == 1 ]] ||
  fail "a backend passed as an argument is the only one that reaches the application" "$flags"
grep -qx -- '--password-store=basic' <<<"$flags" ||
  fail "a backend passed as an argument reaches the application" "$flags"
echo "ok - a backend passed as an argument is the only one that reaches the application"

# A backend the user spelled with a space is two flags, and the first one is
# the switch the launcher has to recognise. The user's own spelling reaches
# the application untouched.
printf -- '--password-store basic\n' >"$config/claude-desktop-flags.conf"
flags=$(run_launcher)
[[ $(backend_flags <<<"$flags") == 1 ]] ||
  fail "a backend spelled with a space is the only one that reaches the application" "$flags"
grep -qx -- '--password-store' <<<"$flags" ||
  fail "a backend spelled with a space reaches the application" "$flags"
grep -qx -- 'basic' <<<"$flags" ||
  fail "the value of a backend spelled with a space reaches the application" "$flags"
echo "ok - a backend spelled with a space is the only one that reaches the application"

# A desktop Electron can detect has a backend of its own: GNOME stores in the
# keyring, KDE in kwallet. The launcher leaves those alone, so a machine
# without a Secret Service provider keeps working.
for desktop in GNOME KDE; do
  rm -f "$config/claude-desktop-flags.conf"
  XDG_CURRENT_DESKTOP="$desktop" flags=$(run_launcher)
  [[ $(backend_flags <<<"$flags") == 0 ]] ||
    fail "a desktop Electron can detect keeps its own backend" "$flags"
done
echo "ok - a desktop Electron can detect keeps its own backend"
