# NVIDIA open kernel modules (DKMS)

NVIDIA's open kernel modules 620.70.06 as DKMS sources, for aarch64 and x86_64, with N1x display fixes on ARM. Machines on `linux-omarchy` get these modules prebuilt from the kernel recipe as `linux-omarchy-nvidia-open` instead; this package is for any other kernel, `linux-omarchy-eevdf` and `linux-omarchy-muqss` included. Based on
[Arch's DKMS recipe](https://gitlab.archlinux.org/archlinux/packaging/packages/nvidia-utils/-/commit/96abcdf4e6bbcdd6da35dde3ee999b1fce1c2a06).
It used to carry Martin Stark's
[NVIDIA PR #1359](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1359)
as `0001`/`0002`; 615.78.08 has NVIDIA's own version of that DisplayPort
detach fix, so they are gone.

It carries `0003-set-oled-edp-brightness-over-aux.patch`: the GPU
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

And `0005-retrain-the-link-after-the-sink-was-unplugged.patch`: when a
DisplayPort monitor came back after an unplug while its head was still
attached, nvkms skipped link training if the link status still read as
trained. Behind a USB4 dock that is every time the dock's DisplayPort tunnel
is rebuilt (the dock is replugged, or the monitor drops out as it wakes), so
the monitor stayed black while the desktop kept it. nvkms now trains the link
again after an unplug. Keep it until NVIDIA's driver does so itself.

And `0006-set-a-mode-afresh-on-a-sink-that-comes-back-through-a-usb4-tunnel.patch`:
the DP library revives the head of a monitor that comes back before the
client noticed it was unplugged. Behind a USB4 dock the DisplayPort tunnel is
new by then and the revived head leaves the monitor black, which happened to
a dock's second monitor whenever the dock was replugged within a few seconds.
On tunnelled links nvkms now reports such a monitor as unplugged until its old
head is shut down, so the client always sets a mode on it afresh.

And `0007-train-a-tunnelled-link-again-when-the-sink-cannot-decode-it.patch`:
behind a USB4 dock, a monitor could come out of standby black at a link that
read as fully trained, while it counted symbol errors on every lane. After
each modeset on a tunnelled link nvkms now reads the monitor's symbol error
counters and, if every lane keeps counting errors, trains the link again.

And `0008-free-the-semaphore-surface-callback-when-the-waiter-is-already-signalled.patch`,
JD Daniels'
[NVIDIA PR #1368](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1368):
when nvidia-drm asked nvkms to wait on a semaphore surface fence that had
already signalled, nvkms returned without freeing the callback record it had
allocated. Under explicit sync that is most composited frames, so the kernel
leaked a small slab object per frame while anything on screen moved, gigabytes
of unreclaimable memory over a few days of uptime. nvkms now frees the record
on that path. Keep it until NVIDIA merges the fix.

The patches are carried for ARM only (`source_aarch64`); x86_64 builds NVIDIA's sources as Arch does.

Requires `[omarchy]` before `[extra]` and matching `nvidia-utils=620.70.06`. Omarchy carries the driver on both architectures; `nvidia-utils`'s README says why and what a driver update changes. Both `linux-omarchy` recipes build the same driver into their prebuilt modules, and `linux-omarchy-aarch64` copies these patches with an `nvidia-` prefix: update them in the same change (`tests/nvidia-open-lockstep.sh` checks them).
