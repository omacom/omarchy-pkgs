# linux-n1x

Experimental Arch-style packaging for NVIDIA's public N1x-era kernel lineage.
The package is pinned to the maintained NVIDIA/Ubuntu 7.0 source currently
closest to the kernel used by NVIDIA's pre-release N1x FastOS systems:

- Ubuntu source release: `7.0.0-1018.18~24.04.1`
- NVIDIA tag: `Ubuntu-nvidia-7.0-7.0.0-1018.18_24.04.1`
- Signed tag object: `5a6b09b7d33204dcd973b1b509137e509b28309b`
- Pinned source commit: `d76db97d0a41dba9bdacca29ff22a0bb511854a9`
- Upstream kernel base: `7.0.14`
- Page size: 4 KiB
- Carried patches (`pkgrel=2`): NVIDIA SAUCE commits `1e2a75fb7d0f` (i2c:
  mediatek: ACPI/MT8901 support, ACPI ID `NVDA0200`) and `c8ca6b82aeb7`
  (gpiolib: acpi: warn-only debounce) from the `26.04_linux-nvidia` branch,
  which is this pinned base plus three commits. The Dell N1x exposes its I2C
  controllers as MediaTek MT8901 IP under `NVDA0200`; the internal keyboard,
  touchpad, and touch panel are HID-over-I2C behind them.

The package exports NVIDIA's `arm64-nvidia` config directly from the pinned
source tree, clears Canonical certificate paths unavailable to an Arch build,
runs `olddefconfig`, and fails closed if the bring-up-critical ACPI, EFI,
SimpleDRM, framebuffer console, serial console, I2C-HID, network, or module
options drift.

This package deliberately contains only the in-tree kernel and headers. The
current development image pairs it with Arch Linux ARM's matching
`nvidia-open-dkms=610.57.04-1`, `nvidia-utils=610.57.04-1`, and GSP firmware.
That is the newest public source pair presently available and explicitly lists
N1x PCI devices `2e03` and `2e06`; NVIDIA's pre-release `2e2a` hardware is known
to use a newer 615-series FastOS stack and may not initialize with 610.57.04.

The package is excluded from unscoped repository builds because it is large
and hardware-specific. Build it explicitly on native aarch64 when possible:

```bash
bin/repo build --arch aarch64 --package linux-n1x
```

The package installs the raw arm64 `Image` for Limine's aarch64 Linux protocol
and does not ship device trees because the observed N1x systems boot through
ACPI. Parallel compilation remains capped at 12 jobs so it can also complete
under x86_64 QEMU emulation.

This is a bring-up artifact, not a supported N1x release. Required physical
validation includes the target PCI identity, console and SSH boot without the
NVIDIA modules, subsequent NVIDIA probe/loading, internal display, keyboard,
networking, suspend/resume, warm reboot, CUDA, and rollback.
