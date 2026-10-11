# libcamera-surface-pro-11

libcamera 0.7.2 with support for the Sony IMX681, the Surface Pro 11's front camera. Arch Linux ARM's libcamera sees the sensor but has no helper for its reciprocal gain register. Without one, automatic exposure takes the raw gain code as the gain, holds exposure down, and the image stays dark indoors.

## Patches

- `0001`: the sensor's unit cell size and control delays (not yet submitted upstream).
- `0002`: the gain helper and black level, Sergey Lebedev's patch as posted to libcamera-devel (https://patchwork.libcamera.org/patch/28155/). An independent helper written for this package was identical. Upstream is holding the patch until a mainline IMX681 kernel driver exists.
- `0003`: simple-IPA tuning with the measured black level and colour correction disabled (not yet submitted upstream).

## Build

Built with the simple pipeline and software ISP, which the Surface's Qualcomm camera subsystem uses, plus uvcvideo and the V4L2 compatibility layer to match Arch's libcamera for USB webcams. The IPA module is stripped and re-signed in `package()`, as Arch's `libcamera-ipa` does, so libcamera loads it in-process.

It provides `libcamera`, `libcamera-ipa` and their sonames, so `pipewire-libcamera` and `libcamera-tools` install against it. It carries no `replaces`, so it never replaces Arch's libcamera on other machines. Only Omarchy's Surface Pro 11 hardware setup installs it. The rear OV13858 camera works with stock libcamera and with this package alike.

It pins libcamera's version, so it must be rebuilt at the same version whenever Arch Linux ARM moves libcamera to a new soname. Otherwise `pipewire-libcamera` cannot upgrade.

## Retirement

Drop once Arch Linux ARM's libcamera includes an IMX681 helper. That needs a mainline IMX681 kernel driver first, so expect this package to be long-lived.
