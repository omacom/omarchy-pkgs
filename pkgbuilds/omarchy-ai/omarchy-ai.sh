#!/usr/bin/env bash
# User launcher for the packaged install under /opt/omarchy-ai.
# Starts the user service without enabling it. Wake models are copied into
# the user's config only when missing; user configuration is left in place.
set -euo pipefail

root=/opt/omarchy-ai
venv="$root/.venv"

if [[ ! -x "$venv/bin/python" ]]; then
  printf 'Omarchy AI is missing its runtime under %s\n' "$root" >&2
  exit 1
fi

if (($#)); then
  exec "$venv/bin/omarchy-ai" "$@"
fi

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-ai/wake_models"
mkdir -p "$config_dir"
shopt -s nullglob
for model in "$root/wake_models/"*.onnx; do
  dest="$config_dir/$(basename "$model")"
  if [[ ! -e "$dest" ]]; then
    cp "$model" "$dest"
  fi
done
shopt -u nullglob

systemctl --user daemon-reload
systemctl --user start omarchy-ai.service

response="$("$venv/bin/omarchy-ai-settings" activate 2>&1)" || {
  printf '%s\n' "$response" >&2
  exit 1
}
if [[ "$response" == *'"state": "offline"'* || "$response" == *'"state":"offline"'* ]]; then
  printf '%s\n' "$response" >&2
  exit 1
fi
printf '%s\n' 'Omarchy AI is running. Say "omachy".'
