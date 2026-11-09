# Omarchy Pi tooling

This package supports the Raspberry Pi 4 Model B on Omarchy's aarch64 UEFI installer. It is not an updater for the community port's U-Boot/ext4 image, and does not enable Pi 5.

`omarchy-pi-check` reads the Device Tree, EFI state, CPU temperature and kernel voltage alarm. `--json` produces a report without serial numbers or network credentials. An unavailable voltage sensor is unknown, not a clean power check. These readings cannot establish peripheral functionality or performance parity with Raspberry Pi OS.

`omarchy-pi-run -- <command> [arguments...]` runs an explicit workload in a user systemd scope, with half of RAM as its soft limit and 65% as its hard limit. Compiler jobs leave a CPU free and use the available memory budget; tighter existing job limits are preserved. `--plan` prints the command. This changes no system-wide performance setting. A workload exceeding the hard limit can be killed; there is no unrestricted fallback if systemd cannot create the scope.

The package adds the Pi's storage/USB dependencies to mkinitcpio. Omarchy's hardware setup invokes `setup-system`, which checks that the board booted with UEFI and a Pi 4 Device Tree, and that the installed kernel includes its drivers. `update-prepare` checks the existing boot files before package changes; `update-verify` repeats the check after all package hooks. The checks require a mounted FAT ESP and a Limine menu entry whose UKI contains the installed `linux-omarchy` kernel byte for byte, with nonempty initramfs and command-line sections. Missing tooling or verification failures stop the update. Kernel rebuilding stays with the existing Limine package hooks. These checks do not prove that the firmware will boot the image or that its initramfs can mount the root filesystem; installation and update/reboot tests are still required.

The early firmware remains on separately prepared UEFI media. Its Device Tree must expose VC4/V3D; the installer refuses a Pi without a V3D render node before disk preparation. This package neither flashes the EEPROM nor rewrites that media. Mainline Pi device-tree/UEFI boot, HDMI/audio, radio firmware, power and update/reboot still need physical qualification with the proposed kernel. The community image's boot report does not validate this path.

No display profile, font, theme, CPU clock, repository, signing policy, user setup, encryption choice or snapshot policy is changed. The display recovery preset and automatic tuning in the community port are intentionally not defaults here.

The diagnostics and build budgeting are adapted from [pkyanam/omarchy-4-pi](https://github.com/pkyanam/omarchy-4-pi). The package is maintained locally with `sync: false`; it has no independent upstream release feed.

## Package update contract

Installed desktops select `raspberrypi-4-desktop`, which depends on this support package at the exact package version and on `omarchy-pi-runtime=1`. Live installer images select only `raspberrypi-4-support`. Support requires `linux-omarchy-pi4=1` from the installed kernel package. Pacman resolves these dependencies before extracting files, so a newer kernel or runtime that drops the capability cannot silently replace a compatible installation. Explicit removal of the desktop/support packages or bypassing dependency checks removes that protection.

The kernel build advertises capability version 1 after checking the packaged Pi 4 board DTB and VC4, V3D, Broadcom PCIe, Broadcom SDHCI and Raspberry Pi firmware drivers as modules or builtins. This is a small boot and graphics contract, not certification of Wi-Fi, Bluetooth, audio, USB devices or power stability. Runtime recipes advertise their capability when the pinned source includes the Pi hardware helper; publishing still requires lifecycle integration and update/reboot qualification of that source.

Publishing must coordinate the capability-bearing kernel, matching headers/NVIDIA packages, runtime/settings source pair, and support/desktop packages in the existing upstream channels. Do not remove temporary package holds until that complete set is available and verified. The local capability patch alone does not make public updates functional. Keep the preceding compatible packages cached for a coordinated downgrade; older packages without these capabilities cannot satisfy the new contract.


## HDMI DDC device access

The BCM2711 HDMI DDC buses use platform controllers `fef04500.i2c` and `fef09500.i2c`, driven by `brcmstb-i2c`. The packaged PCI display-class permission rule does not match that ancestry. `60-omarchy-pi4-ddc.rules` tags only these two i2c-dev controllers for logind's normal active-seat `uaccess` policy. It does not grant group/world access to all I2C buses or depend on unstable bus numbers. This narrow platform rule should be proposed to the upstream ddcutil permission policy as well; the Pi support package owns it until that policy covers the hardware.

The installed systemd rule parser and simulated add events match both real controllers and queue the normal uaccess builtin; the unmodified rules do not. Simulation does not execute that queued builtin. Actual ACL appearance/removal across login/logout and monitor brightness control still need physical qualification. Empty EDID and a failed root DDC read are separate link/driver defects; this permission rule does not repair them.
