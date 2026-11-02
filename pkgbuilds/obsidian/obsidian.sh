#!/bin/bash

# Omarchy keeps Obsidian's launch flags in this file (config/obsidian/user-flags.conf)
# and reads them the way Arch's obsidian package does.
OBSIDIAN_USER_FLAGS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/obsidian/user-flags.conf"

if [[ -f $OBSIDIAN_USER_FLAGS_FILE ]]; then
  OBSIDIAN_USER_FLAGS=$(grep -v '^#' "$OBSIDIAN_USER_FLAGS_FILE")
fi

exec /opt/obsidian/obsidian $OBSIDIAN_USER_FLAGS "$@"
