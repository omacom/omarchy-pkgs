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
fi

# Both app locations use namespaces, never a user-writable setuid helper.
if ! timeout 5 unshare --user --map-root-user true 2>/dev/null; then
  echo "Hermes Desktop requires working unprivileged user namespaces for its sandbox." >&2
  exit 1
fi

# runtime_ok says whether the runtime under HERMES_HOME is usable at all, which is a
# different question from which app binary is executable: the app beside it is built from
# that same checkout, so it takes the runtime, while the packaged /opt app was built from
# the package's release commit and cannot drive a runtime built from another one.
runtime_ok=0
python=/usr/bin/python
if [[ -x $runtime/venv/bin/python && -f $runtime/hermes_cli/main.py ]]; then
  python="$runtime/venv/bin/python"
  runtime_ok=1
else
  runtime=""
fi
exec "$python" - "$native" "$runtime" "$runtime_ok" "$@" <<'PY'
import os
from pathlib import Path
import sys

native, runtime, runtime_ok, *args = sys.argv[1:]
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

        # The helper grew a trailing renderer_accessibility field, so accept any arity
        # rather than pinning the packaged launcher to one release.
        options = list(_desktop_launch_options())
        flags, gpu, store, ozone = (options + ["auto"] * 4)[:4]
        a11y = bool(options[4]) if len(options) > 4 else True
        env = with_hermes_node_path(env)
    except ImportError:
        print("Could not load Hermes desktop settings; using launch defaults.", file=sys.stderr)

if runtime_ok == "1":
    env["HERMES_DESKTOP_HERMES_ROOT"] = runtime
else:
    # A packaged app beside a runtime it was not built from: Desktop owns the install, so
    # 'connect or install' is the honest offer. An explicit request to keep ignoring it wins.
    env.setdefault("HERMES_DESKTOP_IGNORE_EXISTING", "1")

env["HERMES_DESKTOP_CWD"] = os.getcwd()
if gpu != "auto":
    env.setdefault("HERMES_DESKTOP_DISABLE_GPU", gpu)
if ozone != "auto":
    env.setdefault("ELECTRON_OZONE_PLATFORM_HINT", ozone)
env.setdefault("HERMES_DESKTOP_PASSWORD_STORE", store if store != "auto" else "gnome-libsecret")
# Renderer accessibility is ON inside the app by default; bridge only the opt-out.
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
