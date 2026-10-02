# linux-n1x

Experimental Arch-style packaging for NVIDIA's public N1x-era kernel lineage.
The package is pinned to the maintained NVIDIA/Ubuntu 7.0 source that carries
NVIDIA's N1x platform support:

- Ubuntu source release: `7.0.0-1021.21~24.04.1`
- NVIDIA tag: `Ubuntu-nvidia-7.0-7.0.0-1021.21_24.04.1`
- Signed tag object: `ed7f113ad0f665909967aa4e14a4341d0d88949b`
- Pinned source commit: `dd99802c8b0c384169bb36293c9517fa67238e47`
- Upstream kernel base: `7.0.14`
- Page size: 4 KiB
- Carried patches (`pkgrel=3`): four hid-asus patches for the ASUS ProArt P14
  (H7407BA) keyboard, 0B05:4B42: the upstream Zenbook A16 support (Fn keys), a
  keyboard backlight LED for systems without asus-wmi, host-controlled Fn-lock,
  and turning off the keyboard's OOBE mode, which otherwise keeps fading the
  backlight in and out.

1021.21 includes the MediaTek MT8901 I2C and gpiolib debounce SAUCE that
earlier revisions cherry-picked (the Dell N1x exposes its I2C controllers as
MediaTek MT8901 IP under `NVDA0200`; the internal keyboard, touchpad, and touch
panel are HID-over-I2C behind them), the ARML0002 FF-A embedded controller
driver (battery, AC, lid, thermal, UCSI), and MT8901 SoundWire audio.

The package exports NVIDIA's `arm64-nvidia` config directly from the pinned
source tree, clears Canonical certificate paths unavailable to an Arch build,
runs `olddefconfig`, and fails closed if the bring-up-critical ACPI, EFI,
SimpleDRM, framebuffer console, serial console, I2C-HID, network, or module
options drift.

This package deliberately contains only the in-tree kernel and headers. It
pairs with Omarchy's `nvidia-open-dkms` and `nvidia-utils` 615.71.09, which
drive the N1x GPU (PCI `10de:2e03` on the ASUS ProArt P14) including the
internal panel's backlight.

The package is excluded from unscoped repository builds because it is large
and hardware-specific. Build it explicitly on native aarch64 when possible:

```bash
bin/repo build --arch aarch64 --package linux-n1x
```

The package installs the raw arm64 `Image` for Limine's aarch64 Linux protocol
and does not ship device trees because the observed N1x systems boot through
ACPI. Compilation uses every core of the (native aarch64) build host.

This is a bring-up artifact, not a supported N1x release. Required physical
validation includes the target PCI identity, console and SSH boot without the
NVIDIA modules, subsequent NVIDIA probe/loading, internal display, keyboard,
networking, suspend/resume, warm reboot, CUDA, and rollback.
