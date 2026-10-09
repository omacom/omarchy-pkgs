#!/bin/bash
set -euo pipefail

unset ELECTRON_RUN_AS_NODE PYTHONPATH PYTHONHOME

hermes_home=$(realpath -ms -- "${HERMES_HOME:-$HOME/.hermes}")
parent=${hermes_home%/*}
if [[ ${parent##*/} == [Pp][Rr][Oo][Ff][Ii][Ll][Ee][Ss] ]]; then
  hermes_home=${parent%/*}
  hermes_home=${hermes_home:-/}
fi
export HERMES_HOME="$hermes_home"
runtime="$hermes_home/hermes-agent"
native="$runtime/apps/desktop/release/linux-unpacked/Hermes"
if [[ ! -x $native || ! -x $runtime/venv/bin/hermes ]]; then
  native=/opt/hermes-desktop/Hermes
  # Only the packaged app, built from the release commit rather than the runtime's
  # checkout, is told to skip an existing Hermes.
  export HERMES_DESKTOP_IGNORE_EXISTING=${HERMES_DESKTOP_IGNORE_EXISTING:-1}
fi

# Both app locations use namespaces, never a user-writable setuid helper.
if ! timeout 5 unshare --user --map-root-user true 2>/dev/null; then
  echo "Hermes Desktop requires working unprivileged user namespaces for its sandbox." >&2
  exit 1
fi

python=/usr/bin/python
if [[ -x $runtime/venv/bin/python && -f $runtime/hermes_cli/main.py ]]; then
  python="$runtime/venv/bin/python"
else
  runtime=""
fi
exec "$python" - "$native" "$runtime" "$@" <<'PY'
import os
from pathlib import Path
import sys

native, runtime, *args = sys.argv[1:]
env = os.environ.copy()
flags, gpu, store, ozone, a11y = [], "auto", "auto", "auto", True
if runtime:
    sys.path.insert(0, runtime)
    try:
        # Upstream moved the helper out of main after the packaged release.
        if Path(runtime, "hermes_cli/main_desktop.py").is_file():
            from hermes_cli.main_desktop import _desktop_launch_options
        else:
            from hermes_cli.main import _desktop_launch_options
        from hermes_constants import with_hermes_node_path

        # Newer runtimes append renderer_accessibility; the packaged release returns four.
        flags, gpu, store, ozone, *extra = _desktop_launch_options()
        if extra:
            a11y = extra[0]
        env = with_hermes_node_path(env)
    except ImportError:
        print("Could not load Hermes desktop settings; using launch defaults.", file=sys.stderr)

env["HERMES_DESKTOP_CWD"] = os.getcwd()
if gpu != "auto":
    env.setdefault("HERMES_DESKTOP_DISABLE_GPU", gpu)
if ozone != "auto":
    env.setdefault("ELECTRON_OZONE_PLATFORM_HINT", ozone)
env.setdefault("HERMES_DESKTOP_PASSWORD_STORE", store if store != "auto" else "gnome-libsecret")
# The app keeps its accessibility tree on unless told otherwise, so bridge only the opt-out.
if not a11y:
    env.setdefault("HERMES_DESKTOP_RENDERER_ACCESSIBILITY", "0")

# Explicit config, environment and command-line choices override the Wayland default.
if (env.get("WAYLAND_DISPLAY") or env.get("XDG_SESSION_TYPE") == "wayland") and (
    "ELECTRON_OZONE_PLATFORM_HINT" not in env
    and not any(arg.startswith(("--ozone-platform=", "--ozone-platform-hint=")) for arg in flags + args)
):
    flags.insert(0, "--ozone-platform=wayland")
os.execve(native, [native, "--disable-setuid-sandbox", *flags, *args], env)
PY
