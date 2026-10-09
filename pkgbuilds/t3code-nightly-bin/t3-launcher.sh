#!/bin/bash
# The T3 Code server CLI (`t3`) ships inside the app bundle.
# The bundled Electron doubles as the
# Node runtime for it, so the desktop package can put the CLI on PATH without
# shipping a second runtime. Electron's fs layer reads app.asar transparently
# in this mode.
set -euo pipefail

export ELECTRON_RUN_AS_NODE=1
exec /usr/lib/t3code-nightly/t3code /usr/lib/t3code-nightly/resources/app.asar/apps/server/dist/bin.mjs "$@"
