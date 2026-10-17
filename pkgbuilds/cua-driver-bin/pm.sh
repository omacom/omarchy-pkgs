#!/bin/bash
# Stands in for the vendor installer. cua-driver-bin points the binary's
# `update --apply` here instead of https://cua.ai/driver/install.sh, which
# would otherwise install a second copy under ~/.cua-driver and link it into
# ~/.local/bin, stepping around pacman and the repository's release gate. The
# exit status is what `cua-driver update --apply` reports.
{
  echo "cua-driver is installed by pacman (cua-driver-bin), so the vendor installer is disabled."
  echo "Upgrade it with pacman instead:"
  echo "  sudo pacman -Syu cua-driver-bin"
} >&2
exit 1
