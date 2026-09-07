#!/bin/bash
# The T3 Code server CLI (`t3`) ships inside the app bundle; upstream only
# distributes it separately through npm. The bundled Electron doubles as the
# Node runtime for it, so the desktop package can put the CLI on PATH without
# shipping a second runtime. Electron's fs layer reads app.asar transparently
# in this mode.
set -euo pipefail

export ELECTRON_RUN_AS_NODE=1
exec /usr/lib/t3code/t3code /usr/lib/t3code/resources/app.asar/apps/server/dist/bin.mjs "$@"
