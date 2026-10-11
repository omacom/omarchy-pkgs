# power-profiles-daemon-surface-pro-11

On the Surface Pro 11 (Snapdragon X Elite), the Surface Aggregator's performance mode is exposed by the kernel as `/sys/class/platform-profile/platform-profile-0`. The device has no ACPI, so the legacy `/sys/firmware/acpi/platform_profile` path power-profiles-daemon reads does not exist, and it falls back to its placeholder driver: profile changes reach nothing.

This package builds power-profiles-daemon 0.30 with a patch that reads the class device and accepts the kernel's `balanced-performance` spelling. It installs only the daemon under `/usr/lib/power-profiles-daemon-surface-pro-11/` and selects it with a drop-in for `power-profiles-daemon.service`; Arch's package keeps everything else, and removing this package restores the stock daemon. It builds the same release as Arch's package and requires at least that version. An upstream watch flags new releases, so this package can move with Arch's.

## Retirement

Drop once power-profiles-daemon supports platform-profile class devices (upstream issue 178, https://gitlab.freedesktop.org/upower/power-profiles-daemon/-/work_items/178). The patch also fixes the `balanced-performance` spelling, which is worth sending upstream on its own.
