# lib32-nvidia-utils

Arch Linux's `lib32-nvidia-utils` recipe at [75afb40f](https://gitlab.archlinux.org/archlinux/packaging/packages/lib32-nvidia-utils/-/commit/75afb40f7528528af966d79ccb9d370aab30a3b0), unchanged but for `pkgrel`, which sits above Arch's.

Omarchy carries the NVIDIA driver on x86_64 so the `linux-omarchy` kernel can ship its NVIDIA modules prebuilt, pinned to one `nvidia-utils` version. `lib32-nvidia-utils` depends on `nvidia-utils=$pkgver`, so Arch's multilib build would stop installing the moment Arch moved to a driver Omarchy hasn't. Update it with `nvidia-utils`, `nvidia-open-dkms` and every kernel recipe's `_nvidiaver`; `tests/nvidia-open-lockstep.sh` checks they agree.
