#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export HOME="$test_tmp/home" XDG_CONFIG_HOME="$test_tmp/config" XDG_DATA_HOME="$test_tmp/data"
export SUPERWHISPER_TEST_LOG="$test_tmp/calls"
mkdir -p "$test_tmp/bin" "$HOME/.local/bin" "$XDG_CONFIG_HOME/systemd/user" "$XDG_DATA_HOME/superwhisper/app/old"
export PATH="$test_tmp/bin:$PATH"
for command in systemctl xdg-mime  superwhisper; do
  cat > "$test_tmp/bin/$command" <<'SH'
#!/bin/bash
printf '%s %s\n' "${0##*/}" "$*" >> "$SUPERWHISPER_TEST_LOG"
[[ $* != *is-active* ]]
SH
done
cat > "$test_tmp/bin/omarchy-shell" <<'SH'
#!/bin/bash
printf '%s %s\n' "${0##*/}" "$*" >> "$SUPERWHISPER_TEST_LOG"
[[ $1 != "-q" ]] || exit 0
[[ ${SUPERWHISPER_SHELL_ABSENT:-0} != 1 ]] || exit 1
if [[ $* == *putBarWidget* ]]; then
  count=0
  [[ ! -f $SUPERWHISPER_PANEL_COUNT ]] || read -r count < "$SUPERWHISPER_PANEL_COUNT"
  printf '%s\n' "$((count + 1))" > "$SUPERWHISPER_PANEL_COUNT"
  if (( count < 2 )); then
    echo 'not ready'
  else
    echo ok
  fi
fi
SH
export SUPERWHISPER_PANEL_COUNT="$test_tmp/panel-count"
chmod +x "$test_tmp/bin/"*
cat > "$HOME/.local/bin/superwhisper" <<'SH'
#!/bin/bash
exec "${XDG_DATA_HOME:-$HOME/.local/share}/superwhisper/app/current/run.sh" "$@"
SH
printf '%s\n' 'ExecStart=%h/.local/bin/superwhisper daemon' > "$XDG_CONFIG_HOME/systemd/user/superwhisper.service"
ln -s "$XDG_DATA_HOME/superwhisper/app/old" "$XDG_DATA_HOME/superwhisper/app/current"
printf '%s\n' 'retained model' > "$XDG_DATA_HOME/superwhisper/app/old/model"
mkdir -p "$XDG_CONFIG_HOME/superwhisper"
printf '%s\n' 'retained preferences' > "$XDG_CONFIG_HOME/superwhisper/preferences.json"

bash "$ROOT/pkgbuilds/superwhisper-bin/setup-user"
[[ $(readlink "$HOME/.local/bin/superwhisper") == "/usr/bin/superwhisper" ]]
[[ $(readlink "$XDG_DATA_HOME/superwhisper/app/current") == "/opt/superwhisper" ]]
[[ ! -e $XDG_CONFIG_HOME/systemd/user/superwhisper.service ]]
compgen -G "$XDG_CONFIG_HOME/systemd/user/superwhisper.service.before-opr.*" >/dev/null
compgen -G "$HOME/.local/bin/superwhisper.before-opr.*" >/dev/null
[[ $(cat "$XDG_DATA_HOME/superwhisper/app/old/model") == "retained model" ]]
[[ $(cat "$XDG_CONFIG_HOME/superwhisper/preferences.json") == "retained preferences" ]]
grep -Fxq 'systemctl --user disable --now superwhisper-update.timer' "$SUPERWHISPER_TEST_LOG"
grep -Fxq 'systemctl --user restart superwhisper.service' "$SUPERWHISPER_TEST_LOG"
[[ $(readlink "$XDG_CONFIG_HOME/omarchy/plugins/superwhisper-panel") == "/opt/superwhisper/assets/omarchy-plugin/superwhisper-panel" ]]
[[ $(readlink "$HOME/.agents/skills/superwhisper") == "/opt/superwhisper/assets/agent-skill/superwhisper" ]]
bash "$ROOT/pkgbuilds/superwhisper-bin/setup-user"
(( $(grep -c '^omarchy-shell shell putBarWidget ' "$SUPERWHISPER_TEST_LOG") == 3 ))
[[ ! -e $XDG_CONFIG_HOME/superwhisper/omarchy-panel.pending ]]
printf '%s\n' 'PASS: Superwhisper setup migrates portable wrappers with backups, preserves data, and keeps the panel placement'

# A fresh install supplies the user launcher and current link the vendor panel
# expects, without installing a private updater or touching Hyprland config.
export HOME="$test_tmp/fresh" XDG_CONFIG_HOME="$test_tmp/fresh-config" XDG_DATA_HOME="$test_tmp/fresh-data"
bash "$ROOT/pkgbuilds/superwhisper-bin/setup-user"
[[ $(readlink "$HOME/.local/bin/superwhisper") == "/usr/bin/superwhisper" ]]
[[ $(readlink "$XDG_DATA_HOME/superwhisper/app/current") == "/opt/superwhisper" ]]
[[ ! -e $XDG_CONFIG_HOME/hypr ]]
python3 - "$XDG_CONFIG_HOME/superwhisper/preferences.json" <<'PY_TEST'
import json
import os
import sys
with open(sys.argv[1]) as profile:
  preferences = json.load(profile)
assert preferences["toggleRecordingShortcut"] == "Alt+Space"
assert preferences["pushToTalkShortcut"] == ""
assert preferences["cancelRecordingShortcut"] == "Escape"
assert os.stat(sys.argv[1]).st_mode & 0o777 == 0o600
PY_TEST
printf '%s\n' 'PASS: fresh Superwhisper setup uses the package and needs no personal Hyprland config'

# Missing shell cannot fail backend setup; placement retries next time.
export HOME="$test_tmp/deferred" XDG_CONFIG_HOME="$test_tmp/deferred-config" XDG_DATA_HOME="$test_tmp/deferred-data"
SUPERWHISPER_SHELL_ABSENT=1 bash "$ROOT/pkgbuilds/superwhisper-bin/setup-user" 2> "$test_tmp/panel-warning"
[[ -f $XDG_CONFIG_HOME/superwhisper/omarchy-panel.pending ]]
bash "$ROOT/pkgbuilds/superwhisper-bin/setup-user"
[[ ! -e $XDG_CONFIG_HOME/superwhisper/omarchy-panel.pending ]]
printf '%s\n' 'PASS: asynchronous panel discovery retries and unavailable shell does not abort setup'


# The packaged launcher must put the native include in a file Hyprland never
# loads, for the daemon as well as clients. Model the verified vendor contract.
cat > "$test_tmp/vendor-run" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$SUPERWHISPER_TEST_LOG"
printf '%s\n' '-- Generated native include' > "$SUPERWHISPER_HYPR_BINDINGS"
SH
chmod +x "$test_tmp/vendor-run"
sed "s|/opt/superwhisper/run.sh|$test_tmp/vendor-run|" "$ROOT/pkgbuilds/superwhisper-bin/superwhisper" > "$test_tmp/launcher"
mkdir -p "$XDG_CONFIG_HOME/hypr"
printf '%s\n' 'personal bindings' > "$XDG_CONFIG_HOME/hypr/bindings.lua"
for action in daemon 'shortcuts apply' 'shortcuts set hold none'; do
  bash "$test_tmp/launcher" $action
done
[[ $(cat "$XDG_CONFIG_HOME/hypr/bindings.lua") == "personal bindings" ]]
[[ $(cat "$XDG_CONFIG_HOME/superwhisper/hypr-block.lua") == "-- Generated native include" ]]
if bash "$test_tmp/launcher" update apply; then
  echo 'FAIL: the portable updater must not replace a packaged installation' >&2
  exit 1
fi
printf '%s\n' 'PASS: packaged daemon and clients redirect native includes and refuse the private updater'

# A daemon that never becomes ready must stop user setup with a useful error.
cat > "$test_tmp/bin/superwhisper" <<'SH'
#!/bin/bash
exit 1
SH
cat > "$test_tmp/bin/sleep" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$test_tmp/bin/superwhisper" "$test_tmp/bin/sleep"
if bash "$ROOT/pkgbuilds/superwhisper-bin/setup-user" 2> "$test_tmp/startup-error"; then
  echo 'FAIL: user setup must report a daemon that failed to start' >&2
  exit 1
fi
grep -Fq 'Superwhisper did not become ready' "$test_tmp/startup-error"
printf '%s\n' 'PASS: user setup fails clearly when the daemon never becomes ready'

# Exercise the actual packaging rewrite with vendor import variations.
python3 - "$ROOT/pkgbuilds/superwhisper-bin/PKGBUILD" "$test_tmp/palette" <<'PY_TEST'
from pathlib import Path
import subprocess
import sys

recipe = Path(sys.argv[1]).read_text()
patch = recipe.split("<<'PYTHON'\n", 1)[1].split("\nPYTHON\n", 1)[0]
folder = Path(sys.argv[2])
folder.mkdir()
qml = folder / "Panel.qml"
for imports in ("import qs.Commons", "import qs.Commons 1.0", "import qs.Commons\nimport qs.Commons as Commons"):
  qml.write_text(imports + "\nItem { property color ink: Color.foreground }\n")
  subprocess.run([sys.executable, "-", str(folder)], input=patch, text=True, check=True)
  result = qml.read_text()
  assert result.count("import qs.Commons as Commons") == 1
  assert "Commons.Color.foreground" in result
for imports in ("import QtQuick", "import qs.Commons\nimport qs.Commons as Commons\nimport qs.Commons as Commons"):
  qml.write_text(imports + "\nItem { property color ink: Color.foreground }\n")
  result = subprocess.run([sys.executable, "-", str(folder)], input=patch, text=True, capture_output=True)
  assert result.returncode != 0, "invalid imports must fail packaging"
PY_TEST
printf '%s\n' 'PASS: palette rewrite handles existing/versioned imports and fails on missing or duplicate aliases'
