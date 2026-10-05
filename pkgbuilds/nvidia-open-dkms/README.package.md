# NVIDIA ARM DisplayPort detach fix

ARM-only edge package carrying Martin Stark's pending
[NVIDIA PR #1359](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1359)
to fix DisplayPort disconnect cleanup in 615.71.09. Based on
[Arch's DKMS recipe](https://gitlab.archlinux.org/archlinux/packaging/packages/nvidia-utils/-/commit/f9ae10b379f8b1d0832ec92bca1c12072aa123e9).

It also carries `0003-set-oled-edp-brightness-over-aux.patch`: the GPU
firmware sets an internal panel's brightness as PWM or a VESA eDP level, and
the Dell XPS 16 (N1x)'s eDP 1.5 OLED panel ignores both. nvkms also sets it as
a target luminance, as the kernel's `drm_edp_backlight` helpers do for i915
and amdgpu, but only on eDP 1.5 panels without a PWM input that support
luminance control; everything else stays with the firmware. Keep it until
NVIDIA's driver sets these panels itself.

And `0004-drive-both-displays-of-a-dock-on-one-n1x-usb4-port.patch`: on the
N1x a USB4 port's two DisplayPort IN adapters are two USB-C connectors on one
DP pad-link, each with its own SOR, but the GPU firmware's head routing map
lets a pad-link drive one display only. A dock's second display never lit.
When the firmware rejects a set of displays, nvkms asks again with one USB-C DP
connector per shared pad-link and accepts the set if that passes. Keep it until
NVIDIA's firmware routes both adapters itself.

Requires `[omarchy]` before `[extra]` and matching `nvidia-utils=615.71.09`.
Update both NVIDIA packages together; automatic version tracking is disabled.

Remove this recipe and the published package/database entry once a fixed
Arch Linux ARM driver is validated. A stale package in the earlier repository
can block driver updates.
