# NVIDIA ARM DisplayPort detach fix

ARM-only edge package carrying Martin Stark's pending
[NVIDIA PR #1359](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1359)
to fix DisplayPort disconnect cleanup in 615.71.09. Based on
[Arch's DKMS recipe](https://gitlab.archlinux.org/archlinux/packaging/packages/nvidia-utils/-/commit/f9ae10b379f8b1d0832ec92bca1c12072aa123e9).

Requires `[omarchy]` before `[extra]` and matching `nvidia-utils=615.71.09`.
Update both NVIDIA packages together; automatic version tracking is disabled.

Remove this recipe and the published package/database entry once a fixed
Arch Linux ARM driver is validated. A stale package in the earlier repository
can block driver updates.
