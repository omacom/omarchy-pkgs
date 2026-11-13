# nvidia-utils

Arch Linux's `nvidia-utils` recipe at [96abcdf4e6bbcdd6da35dde3ee999b1fce1c2a06](https://gitlab.archlinux.org/archlinux/packaging/packages/nvidia-utils/-/commit/96abcdf4e6bbcdd6da35dde3ee999b1fce1c2a06), for aarch64 and x86_64, building `nvidia-utils` and `opencl-nvidia`. Upstream contributor credits, packaging license and support files are retained. Its `nvidia-open-dkms` output is the `nvidia-open-dkms` recipe here, which carries the N1x patches on ARM.

## Why Omarchy carries the driver

The `linux-omarchy` kernel recipes (x86_64 and aarch64) build NVIDIA's open modules into a prebuilt `linux-omarchy-nvidia-open` package, so NVIDIA machines don't compile them through DKMS on each kernel update. Those modules only work with the userspace of the same version, so they depend on `nvidia-utils=$pkgver`, and that pin is only safe while Omarchy decides when the driver moves: if Arch's `nvidia-utils` moved first, `pacman -Syu` would refuse the upgrade on every NVIDIA machine until the kernels were rebuilt. `[omarchy]` comes before `[extra]`, so this recipe shadows Arch's on both architectures, and `pkgrel` sits above Arch's.

There is deliberately no automatic version watcher. A driver update is one change to `nvidia-utils`, `lib32-nvidia-utils`, `nvidia-open-dkms` (rebasing the ARM patches), and `_nvidiaver` plus a `pkgrel` bump in `linux-omarchy` and `linux-omarchy-aarch64`, so the kernels' modules publish with the userspace they match. `tests/nvidia-open-lockstep.sh` fails when they disagree. Follow Arch's releases: a driver that stays behind Arch for long holds back machines that run Arch's own `nvidia-open` for a stock kernel, since it pins Arch's `nvidia-utils`.

## ARM correction

NVIDIA 615.71.09's ARM EGL/GLX libraries require `libnvidia-rmapi-tegra.so.615.71.09`. NVIDIA includes it in its archive, but the Arch recipe omits it. Adding that library and its generated symlink fixes Hyprland's EGL initialization failure on DGX Spark. No rendering overrides are installed. The correction passed package installation, normal desktop login and reboot on a Spark running kernel 7.2.6 with NVIDIA 615.71.09. 620.70.06's `libnvidia-eglcore`, `libnvidia-glcore` and `libnvidia-glsi` still link to it and Arch's 620.70.06 recipe still omits it, so the correction stays. The upstream Arch submission is pending account approval; drop the correction once Arch ships the library.
