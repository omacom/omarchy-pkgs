#!/bin/bash
# Launches Feishu with the flags in $XDG_CONFIG_HOME/feishu-flags.conf: whitespace-separated,
# not shell-quoted, with # starting a comment.

flags=()
conf="${XDG_CONFIG_HOME:-$HOME/.config}/feishu-flags.conf"
if [[ -r $conf ]]; then
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%%#*}"
    [[ -n ${line//[[:space:]]/} ]] || continue
    read -r -a words <<<"$line"
    flags+=("${words[@]}")
  done <"$conf"
fi

# Native Wayland draws sharp on scaled displays and takes fcitx5 input through
# text-input-v3; a platform the user picked wins.
platform=()
if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
  platform=(--ozone-platform=wayland --enable-wayland-ime --wayland-text-input-version=3)
  for flag in "${flags[@]}" "$@"; do
    [[ $flag == --ozone-platform=* || $flag == --ozone-platform-hint=* ]] && platform=()
  done
fi

exec /opt/bytedance/feishu/bytedance-feishu "${platform[@]}" "${flags[@]}" "$@"
