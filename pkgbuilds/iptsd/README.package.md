# iptsd

Userspace touch and pen processing for Microsoft Surface digitizers, built from pinned upstream `linux-surface/iptsd` v3.1.0 against Arch Linux libraries. Arch Linux ARM does not package it, and the AUR carries only an unmaintained `iptsd-git`.

On the Surface Pro 11 (Snapdragon X Elite), the HID-over-SPI digitizer delivers touch through the kernel, but the pen only works once iptsd processes the raw digitizer reports into its virtual stylus and touchscreen devices. It is installed by Omarchy's `install/hardware/microsoft/surface-pro-11.sh`.

Upstream's udev rule runs `iptsd-check-device` on every hidraw device and starts `iptsd@<device>.service` only for supported Surface digitizers. The package is aarch64-only: Intel Surfaces get iptsd from the linux-surface repository, and publishing it for x86_64 here would collide with that package.

The packaged udev rule also runs on "change" events. Upstream's runs only on "add", so the udev reload pacman performs whenever a package ships udev rules stopped iptsd until the next boot (linux-surface/iptsd issue 163).

## Retirement

Drop once Arch Linux ARM packages iptsd, or once the Surface Pro 11's pen works through the kernel alone.
