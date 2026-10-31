#!/bin/sh

export BIONIC_SYSTEM_MANAGED_UPDATES=1
exec /opt/lm-studio-bionic/Bionic.AppImage "$@"
