#!/bin/bash
# Runs a built quickshell against two small configs that use OmarchyLoadPatch
# (load_qtquick_611.patch) and fails if the patch stops doing its job:
#
#   1. A config singleton named Color still wins over the Color singleton that
#      Qt 6.12 added to QtQuick, which is what the patch is for.
#   2. A .pragma library script is one instance, whether a file is loaded by
#      URL or as a type (#978).
#
#   load-patch-check.sh <quickshell binary>
set -euo pipefail
qs=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/cfg" "$work/ext" "$work/home"
# A build runs under fakeroot or a builder account whose HOME may not be
# writable: give quickshell its own home and runtime dir.
mkdir -m 700 "$work/run"
export HOME="$work/home" XDG_RUNTIME_DIR="$work/run"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME

cat >"$work/cfg/Color.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject { readonly property string origin: "config" }
QML

printf '.pragma library\nvar tag = Math.random().toFixed(4)\n' >"$work/ext/Lib.js"
for entry in A B; do
  cat >"$work/ext/$entry.qml" <<QML
import QtQuick
import "Lib.js" as Lib
Item {
  Component.onCompleted: console.log("check-tag $entry", Lib.tag)
  T1 { who: "$entry.T1" }
  T2 { who: "$entry.T2" }
}
QML
done
for type in T1 T2; do
  cat >"$work/ext/$type.qml" <<'QML'
import QtQuick
import "Lib.js" as Lib
Item { property string who; Component.onCompleted: console.log("check-tag", who, Lib.tag) }
QML
done

cat >"$work/cfg/shell.qml" <<QML
//@ pragma OmarchyLoadPatch
import QtQuick
import Quickshell
ShellRoot {
  Component.onCompleted: console.log("check-color", Color.origin)
  Loader { source: "file://$work/ext/A.qml" }
  Loader { source: "file://$work/ext/B.qml" }
  Timer { interval: 1000; running: true; onTriggered: Qt.quit() }
}
QML

QT_QPA_PLATFORM=offscreen timeout 20 "$qs" -p "$work/cfg" --no-color >"$work/log" 2>&1 || true

fail=0
color=$(sed -n 's/.*check-color //p' "$work/log")
if [[ $color == config ]]; then
  echo "ok: the config's Color singleton wins over QtQuick's"
else
  echo "FAIL: Color resolved to '${color:-nothing}', not the config's singleton"
  fail=1
fi

tags=$(sed -n 's/.*check-tag .* \([0-9.]*\)$/\1/p' "$work/log")
count=$(grep -c . <<<"$tags" || true)
distinct=$(sort -u <<<"$tags" | grep -c . || true)
if [[ $count == 6 && $distinct == 1 ]]; then
  echo "ok: one .pragma library instance across 6 importers"
else
  echo "FAIL: $count importers saw $distinct .pragma library instances (want 6 and 1)"
  fail=1
fi

if (( fail )); then
  cat "$work/log"
  exit 1
fi
