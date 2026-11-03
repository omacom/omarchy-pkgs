# lib32-nvidia-utils

Arch Linux's `lib32-nvidia-utils` recipe at [09dc2d0e](https://gitlab.archlinux.org/archlinux/packaging/packages/lib32-nvidia-utils/-/commit/09dc2d0e16505d584ed35ec73a7a9a5827f6cea5), unchanged but for `pkgrel`, which sits above Arch's.

Omarchy carries the NVIDIA driver on x86_64 so every `linux-omarchy` kernel can ship its NVIDIA modules prebuilt, pinned to one `nvidia-utils` version. `lib32-nvidia-utils` depends on `nvidia-utils=$pkgver`, so Arch's multilib build would stop installing the moment Arch moved to a driver Omarchy hasn't. Update it with `nvidia-utils`, `nvidia-open-dkms` and every kernel recipe's `_nvidiaver`; `tests/nvidia-open-lockstep.sh` checks they agree.
