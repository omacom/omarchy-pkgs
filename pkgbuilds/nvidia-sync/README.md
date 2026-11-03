# NVIDIA Sync

Packages NVIDIA's official Linux desktop app and its native SSH helper for
`aarch64` and `x86_64`. No NVIDIA GPU or driver is required on the client.

Build an installable package from the repository root:

```sh
bin/build --package nvidia-sync --arch aarch64
sudo pacman -U build-output/edge/aarch64/nvidia-sync-*.pkg.tar.zst
```

Launch **NVIDIA Sync** from the application menu or run `nvidia-sync`.
The upstream launcher uses X11; install `xorg-xwayland` on Wayland desktops.
The **Open Terminal** action uses `xdg-terminal-exec` and your configured
terminal, including Ghostty on Omarchy. It does not need the AUR
`nvidia-sync-terminal-fix` package.

The update watch reads NVIDIA's ARM64 APT index and keeps the upstream
build suffix in the Arch version (`0.117.3-12` becomes `0.117.3_12`).
NVIDIA's internal Debian revision is tracked separately so a vendor rebuild
also triggers an update. Updates verify downloads for both architectures.

Sources:

- [NVIDIA setup instructions](https://build.nvidia.com/spark/connect-to-your-spark/sync)
- [NVIDIA ARM64 package index](https://workbench.download.nvidia.com/stable/linux/debian/dists/default/proprietary/binary-arm64/Packages)
- [NVIDIA software license](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-software-license-agreement.md)
- [NVIDIA AI product terms](https://www.nvidia.com/en-us/agreements/enterprise-software/product-specific-terms-for-ai-products.md)

The checked-in license texts are NVIDIA's published Markdown copies,
retrieved October 21, 2026. Third-party notices are fetched per release.
