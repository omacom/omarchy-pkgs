# Temporary NVIDIA ARM packaging correction

Carries Arch Linux's `nvidia-utils` recipe at
[f9ae10b379f8b1d0832ec92bca1c12072aa123e9](https://gitlab.archlinux.org/archlinux/packaging/packages/nvidia-utils/-/commit/f9ae10b379f8b1d0832ec92bca1c12072aa123e9),
restricted to aarch64 and the nvidia-utils output. Upstream contributor credits,
packaging license and support files are retained. The OpenCL/DKMS split outputs
and their unused kernel source preparation are omitted.

NVIDIA 615.71.09's ARM EGL/GLX libraries require
`libnvidia-rmapi-tegra.so.615.71.09`. NVIDIA includes it in its archive, but the
Arch recipe omits it. Adding that library and its generated symlink fixes
Hyprland's EGL initialization failure on DGX Spark. No rendering overrides are
installed. The correction passed package installation, normal desktop login
and reboot on a Spark running kernel 7.2.6 with NVIDIA 615.71.09.

This recipe builds only for edge, using release 1.1 to sit above Arch's broken
release 1 and below a prospective fixed release 2. There is deliberately no
automatic NVIDIA version watcher: driver userspace must remain compatible with
the kernel package supplied by Arch Linux ARM. Check both packages before each
release; a stale overlay must not hold back a driver transition.

## Delivery and removal

Publishing requires an aarch64 edge build. Consumers must put `[omarchy]`
before `[extra]` in pacman.conf for unqualified installation and updates to
select this package. A higher pkgrel alone does not overcome repository order.
The tested Spark has that ordering; this PR does not change shared runtime or
installer configuration. Deployment must verify that ordering on the intended
ARM installation/update paths. This is not a claim of fresh-ISO validation.

The upstream Arch submission is pending account approval. Once Arch Linux ARM
ships the missing library, validate that package on the Spark, remove this
recipe AND the published overlay package/database entry, and verify that normal
updates select the fixed Arch package. A higher Arch version alone does not
bypass an earlier repository's stale package. Do not use an epoch or rename the
package to prevent that transition.
