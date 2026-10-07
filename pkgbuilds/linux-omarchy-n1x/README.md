# linux-omarchy-n1x

The `linux-omarchy` kernel built for aarch64 with NVIDIA N1x (RTX Spark) platform support added. It carries the same kernel.org source and signed Omarchy patch set as `linux-omarchy` 7.2.5-6, plus N1x topic patches numbered 1000 and up. The intent is to fold these into `linux-omarchy` itself once it builds for aarch64; until then this is the kernel Omarchy installs on N1x machines (`install/hardware/n1x.sh` in omarchy), replacing NVIDIA's 7.0-based `linux-n1x`.

The `pkgrel` counts N1x revisions of this package and starts again at 1 when the kernel version changes. It was `6.1` to `6.9` while it tracked `linux-omarchy`'s release; the ninth revision became `9`, `10` adds the Dell XPS 16 patches, and `11` brings a dock's displays back after a failed DisplayPort tunnel.

## N1x patches

Patches 1000–1040 are NVIDIA's SAUCE from `Ubuntu-nvidia-7.0-7.0.0-1021.21_24.04.1` (commit `dd99802c8b0c384169bb36293c9517fa67238e47`), rebased onto 7.2.5 with Omarchy's patches applied and grouped by topic:

- `1000-n1x-mediatek-platform.patch` - MediaTek MT8901 I/O: pinctrl, GPIO, I2C (keyboard, touchpad and touch panel are HID-over-I2C behind it), xHCI, SSPM and power_wrap
- `1010-n1x-ffa-ec.patch` - the ARML0002 FF-A embedded controller (battery, AC, lid, thermal zones, UCSI)
- `1020-n1x-power.patch` - CPPC autonomous mode, GIC, watchdog, pmdomain and idle fixes
- `1030-n1x-audio.patch` - MT8901 SoundWire and ASoC (CS42L43 + CS35L56 on the ASUS ProArt P14), plus a fix for 7.2's `asoc_sdw_parse_sdw_endpoints()` signature
- `1040-n1x-gpu-iommu.patch` - DMA-mode SMMU domains for the integrated GPU (10de:2e00–2e3f); without them GSP fails to boot and the screen stays black

Patches 1011–1013 are our own, for the Dell XPS 16 (DX16263):

- `1011` fills the battery status from EC RAM. Dell's firmware answers the EC battery service's GetBst with zeros, so the battery read empty at 0 V.
- `1012` skips the PSYS/PSOC thermal zones on the XPS 16. There they report power, not temperature, and showed up as zones at 600–1245 °C. It is limited to that model until the ProArt P14's zones are checked.
- `1013` adds `dell-arm64-hotkeys`, which reports the hotkeys Dell's firmware sends as WMI events (mic mute) without the x86-only ACPI-WMI core. The XPS 16's EC never sends its FF-A notifications on BIOS 1.2.0, so on that machine the driver polls the EC's event queue instead (every 250 ms). Its mic-mute LED can only be toggled and stays lit across reboots, so the driver tracks it as `platform::micmute` (which Omarchy's mute script sets) and turns it off at shutdown.

`1050-efi-add-efi_reclaim_reserved-to-use-idle-reserved-memory-as-RAM.patch` is our own: the N1x firmware reserves tens of GiB as the GPU's dedicated memory under Windows (62.5 GiB on the 128 GB ProArt P14), which Linux's driver never uses. `efi_reclaim_reserved=<size>@<start>,...` hands named ranges of it to the kernel, and is ignored unless each range is still entirely reserved, writeback-capable memory. Omarchy sets it per model from `install/hardware`.

`1060-ASoC-mediatek-mt8901-give-the-card-the-ACPI-subsystem-ID.patch` is also our own. Cirrus CS35L56 amplifiers name their DSP firmware and speaker tuning after the sound card's PCI subsystem ID, which the ACPI-enumerated MT8901 card does not have, so they ran on ROM defaults: quiet and unvoiced. The patch reads the SoundWire controller's `_SUB` (written device ID first, `33A11043` on the ProArt P14) and passes it to the card, so the amplifiers request `cs35l56-b0-dsp1-misc-104333a1-spkid0*`. Those files are not in linux-firmware yet.

Patches 1070–1082 make USB4 and Thunderbolt work. The N1x host routers (`\_SB.UBF0..2`, `NVDA8100`, one per USB-C port) are ACPI platform devices rather than PCI NHIs, the firmware hands USB4 to the OS, and it has no connection manager of its own. Without these patches nothing bound them, so PCIe-tunnelled devices (docks, 10G adapters, eGPUs) never appeared, and USB4 docks fell back to USB-C alt modes.

- `1070` reverts NVIDIA's SAUCE that disabled USB4 through a vendor `_DSM`. The ASUS EC doesn't implement that `_DSM`, so the revert also removes a 2 s stall.
- `1071` has `ucsi_acpi` query the `_DSM` functions before using them, as the ACPI spec asks. The ProArt P14 EC opens its UCSI service on that query, and without it every boot logged `PPM init failed` and `/sys/class/typec` stayed empty.
- `1072` adds `power_wrap_drv.usb4_release=`. NVIDIA's power_wrap releases the host routers' SSPM resources once xHCI is up. After that the SSPM stops answering for them, and a later power request hangs it and resets the SoC. `1076` reports whether the release ran, so the driver can refuse to probe.
- `1073`–`1075` let the Thunderbolt core run on a host interface that is not a PCI device, building on 7.2's non-PCI NHI groundwork.
- `1077` is the glue driver itself, `thunderbolt_platform` (`CONFIG_USB4_PLATFORM_NHI`). It maps the host interface, powers it through power_wrap, and services the rings from the one wired level interrupt.
- `1078` fixes PCI bus numbering below a hot-added switch. Without it, `pci=hpbussize`, which the unconfigured tunnel root ports need, let a dock's first downstream port take every bus number, so the ports after it (on a CalDigit TS4, the Ethernet controller) were never enumerated.
- `1079` turns off CL states on the N1x host router's links. With them on, a monitor behind a DisplayPort tunnel failed to sync to its first link training and kept dropping out, so a dock's display usually stayed dark at boot and often on hotplug.
- `1080` keeps the routers out of USB4 sleep during suspend. A router only leaves that sleep through the reset it gets when its host interface loses power, which never happens here, so a port with a device attached stopped answering after resume.
- `1081` stops the driver powering the routers down when it is unbound. The SSPM can turn a router off, but turning it back on does not restore what the boot firmware set up, so the router stayed dead until the next boot.
- `1082` offers the N1x host router's DP IN adapters again when a monitor is plugged in. The connection manager drops a DP IN adapter whose tunnel fails DPRX negotiation until the adapter reports a hotplug, which the N1x's never do, so after one failure every display behind a dock on that port stayed black until reboot.

The driver binds only with `power_wrap_drv.usb4_release=0` on the command line. Omarchy sets that together with the PCI hotplug padding.

SAUCE that was left out:

- `serial: 8250_mtk: Add ACPI support`, the MT7925 CSA patch and the four cpufreq QoS patches are superseded by 7.2
- the ACPI `_LPI` hierarchical idle series (SAUCE 0039–0054 and 0067–0069) is deferred until it is ported to 7.2. Without it, CPU idle uses the flat LPI states only

Patches 1100–1104 are for the ASUS ProArt P14 (H7407BA) keyboard, 0B05:4B42: the upstream Zenbook A16 support (Fn keys), a keyboard backlight LED for systems without asus-wmi, host-controlled Fn-lock, turning off the keyboard's OOBE mode, which otherwise keeps fading the backlight in and out, and turning the backlight off for sleep.

## Config

`config.aarch64` started from NVIDIA's `arm64-nvidia` annotations for the 1021.21 tree, went through `olddefconfig` on 7.2.5, and then had `linux-omarchy`'s behavioral choices applied (preemption, LSM list, zswap and zram defaults, THP, built-in Btrfs, schedutil, I/O schedulers, binder off, no Canonical trusted keys).

## Building

The package is large and hardware-specific, so unscoped repository builds skip it. Build it explicitly, natively on aarch64 where possible:

```bash
bin/repo build --arch aarch64 --package linux-omarchy-n1x
```

The build produces only `Image` and modules; N1x boots through ACPI and the package ships no device trees. It installs the raw arm64 `Image` as `vmlinuz` for Limine's aarch64 Linux protocol.

## Validation

7.2.5-6.5 on the ASUS ProArt P14 H7407BA with `nvidia-open-dkms` 615.71.09 (2026-10-02): LUKS unlock at Plymouth, internal display and brightness, CUDA, keyboard (Fn keys, backlight, Fn-lock), touchpad, speakers, headphones and microphones, battery and AC, Wi-Fi and Bluetooth, webcam, 122 GiB of RAM with `efi_reclaim_reserved=` (the reclaimed ranges kept a written pattern through display, 16 GiB of CUDA work and suspend-to-idle), suspend-to-idle.

7.2.5-6.8 on the same machine (2026-10-03): UCSI and the three USB-C ports' Type-C class devices; a CalDigit TS4 on each of the three USB4 ports with a 40 Gb/s link, its USB3 and 2.5 GbE (`igc`) and a 4K 240 Hz display through its DisplayPort tunnel, at boot and on hotplug; HDMI out; the UHS-II SD reader. Omarchy writes the USB4 kernel options (`power_wrap_drv.usb4_release=0 pci=hpbussize=0x80,hpmmiosize=32M,hpmmioprefsize=32G`) from `install/hardware/n1x.sh`, and a dock or adapter is approved once with `boltctl enroll --policy auto`.

Not yet validated: USB4 devices across suspend (patches 1080 and 1081), lid-driven suspend and battery drain while suspended, warm reboot loops. The firmware's `deep` sleep returns at once, so Omarchy defaults these machines to `s2idle`.
