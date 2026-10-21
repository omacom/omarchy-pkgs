#!/bin/bash

XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-~/.config}

export ELECTRON_OZONE_PLATFORM_HINT="${ELECTRON_OZONE_PLATFORM_HINT:-wayland}"
export NIXOS_OZONE_WL="${NIXOS_OZONE_WL:-1}"
# pacman owns /opt/Grok Bot. The app only knows apt and dnf, so its
# "Restart to update" relaunches the same version and its "Update required"
# screen blocks until the repo catches up. Leave updates to pacman.
export SAND_DISABLE_UPDATES="${SAND_DISABLE_UPDATES:-1}"

if [[ -f $XDG_CONFIG_HOME/grok-bot-flags.conf ]]; then
	GROK_BOT_USER_FLAGS="$(sed 's/#.*//' "$XDG_CONFIG_HOME/grok-bot-flags.conf" | tr '\n' ' ')"
fi

# 0.24.0 renamed the binary sand -> grok-bot.
if [[ -x "/opt/Grok Bot/grok-bot" ]]; then
	GROK_BOT_BIN="/opt/Grok Bot/grok-bot"
else
	GROK_BOT_BIN="/opt/Grok Bot/sand"
fi

exec "$GROK_BOT_BIN" \
	--ozone-platform=wayland \
	--enable-features=UseOzonePlatform,WaylandWindowDecorations \
	--enable-wayland-ime \
	"$@" $GROK_BOT_USER_FLAGS
