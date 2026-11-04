#!/bin/bash
# DingTalk bundles its own Qt 5.15 without a Wayland platform plugin, so it
# runs under XWayland and must load its own Qt plugins, fcitx5 included.
export QT_QPA_PLATFORM=xcb
export QT_PLUGIN_PATH=/opt/dingtalk/release
# Under XWayland the session states its scale as GDK_SCALE. The embedded
# browser follows it already; the Qt windows size themselves from the font DPI.
case ${GDK_SCALE:-} in
  [1-9]) export QT_FONT_DPI="${QT_FONT_DPI:-$((96 * GDK_SCALE))}" ;;
esac
# Its libraries are found through a RUNPATH of ./ and ./plugins/dtwebview.
cd /opt/dingtalk/release || exit 1
# The vendor launcher preloads CEF so its TLS block is allocated at startup.
LD_PRELOAD="./plugins/dtwebview/libcef.so${LD_PRELOAD:+ $LD_PRELOAD}" exec ./com.alibabainc.dingtalk "$@"
