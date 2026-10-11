# linux-omarchy-n1x

The `linux-omarchy` kernel built for aarch64 with NVIDIA N1x (RTX Spark) platform support added. It carries the same kernel.org source and signed Omarchy patch set as `linux-omarchy` 7.2.8-5, plus N1x topic patches numbered 1000 and up. Since 7.2.8-5 `linux-omarchy` is a meta package for `linux-omarchy-bore`, so the shared patches, their signatures and the BORE and ADIOS schedulers come from `linux-omarchy-bore`, byte for byte, including its BORE rebases of the `0121`–`0144` scheduler patches. The intent is to fold these into `linux-omarchy` itself once it builds for aarch64; until then this is the kernel Omarchy installs on N1x machines (`install/hardware/n1x.sh` in omarchy), replacing NVIDIA's 7.0-based `linux-n1x`.

The `pkgrel` counts N1x revisions of this package and starts again at 1 when the kernel version changes. On 7.2.5 it was `6.1` to `6.9` while it tracked `linux-omarchy`'s release; the ninth revision became `9`, `10` added the Dell XPS 16 patches, `11` brought a dock's displays back after a failed DisplayPort tunnel, `12` stopped the clock during suspend-to-idle, `13` brought NVIDIA's device sleep patches from 1022.23, `14` let keyboard and touchpad interrupts wake the system from the platform's deepest sleep, and `15` brought audio and UCSI fixes from upstream and turned kexec handover off by default. `7.2.8-1` moves to 7.2.8 and `linux-omarchy` 7.2.8-5's patch set. `7.2.8-2` ships the Snapdragon laptops' device trees.

[`UPGRADING-7.3.md`](UPGRADING-7.3.md) has notes for the move to 7.3: what each N1x patch needs there, what upstream already has, and how to verify the result.

## N1x patches

Patches 1000–1040 are NVIDIA's SAUCE from `Ubuntu-nvidia-7.0-7.0.0-1021.21_24.04.1` (commit `dd99802c8b0c384169bb36293c9517fa67238e47`), rebased onto 7.2.8 with Omarchy's patches applied and grouped by topic:

- `1000-n1x-mediatek-platform.patch` - MediaTek MT8901 I/O: pinctrl, GPIO, I2C (keyboard, touchpad and touch panel are HID-over-I2C behind it), xHCI, SSPM and power_wrap
- `1010-n1x-ffa-ec.patch` - the ARML0002 FF-A embedded controller (battery, AC, lid, thermal zones, UCSI)
- `1020-n1x-power.patch` - CPPC autonomous mode, GIC, watchdog, pmdomain and idle fixes
- `1030-n1x-audio.patch` - MT8901 SoundWire and ASoC (CS42L43 + CS35L56 on the ASUS ProArt P14), plus a fix for 7.2's `asoc_sdw_parse_sdw_endpoints()` signature
- `1040-n1x-gpu-iommu.patch` - DMA-mode SMMU domains for the integrated GPU (10de:2e00–2e3f); without them GSP fails to boot and the screen stays black

Patches 1011–1013 are our own, for the Dell XPS 16 (DX16263):

- `1011` fills the battery status from EC RAM. Dell's firmware answers the EC battery service's GetBst with zeros, so the battery read empty at 0 V.
- `1012` skips the PSYS/PSOC thermal zones on the XPS 16. There they report power, not temperature, and showed up as zones at 600–1245 °C. It is limited to that model until the ProArt P14's zones are checked.
- `1013` adds `dell-arm64-hotkeys`, which reports the hotkeys Dell's firmware sends as WMI events (mic mute) without the x86-only ACPI-WMI core. The XPS 16's EC never sends its FF-A notifications on BIOS 1.2.0, so on that machine the driver polls the EC's event queue instead (every 250 ms). Its mic-mute LED can only be toggled and stays lit across reboots, so the driver tracks it as `platform::micmute` (which Omarchy's mute script sets) and turns it off at shutdown.

`1021-ACPI-processor_idle-let-LPI-states-freeze-the-tick-in-suspend-to-idle.patch` is our own. Without it, suspend-to-idle on ACPI LPI idle states left timekeeping running, so CLOCK_MONOTONIC kept advancing while the laptop slept. Any sleep longer than three minutes made systemd kill systemd-logind, systemd-journald and boltd for missed watchdog pings as soon as it woke. That dropped the graphical session to the login screen and left NetworkManager asleep with no network. The CPUs enter the same idle state as before; the tick and timekeeping are now frozen as well. On 7.2.8 it sits on Rafael Wysocki's `_LPI` parsing rework from 7.3-rc1, which Omarchy's `0210-pm-updates.patch` brings.

`1050-efi-add-efi_reclaim_reserved-to-use-idle-reserved-memory-as-RAM.patch` is our own: the N1x firmware reserves tens of GiB as the GPU's dedicated memory under Windows (62.5 GiB on the 128 GB ProArt P14), which Linux's driver never uses. `efi_reclaim_reserved=<size>@<start>,...` hands named ranges of it to the kernel, and is ignored unless each range is still entirely reserved, writeback-capable memory. Omarchy sets it per model from `install/hardware`.

`1060-ASoC-mediatek-mt8901-give-the-card-the-ACPI-subsystem-ID.patch` is also our own. Cirrus CS35L56 amplifiers name their DSP firmware and speaker tuning after the sound card's PCI subsystem ID, which the ACPI-enumerated MT8901 card does not have, so they ran on ROM defaults: quiet and unvoiced. The patch reads the SoundWire controller's `_SUB` (written device ID first, `33A11043` on the ProArt P14) and passes it to the card, so the amplifiers request `cs35l56-b0-dsp1-misc-104333a1-spkid0*`. Those files are not in linux-firmware yet.

Patches 1031 and 1032 are audio fixes from upstream that 7.2.8 does not have:

- `1031` (a41da0bb086e, in linux-next; NVIDIA carries it as e2f418271a2c, LP 2167235) gives `snd_hda_acpi`, the driver for the GPU's HDMI and DisplayPort audio controller (NVDA2014), runtime PM callbacks and calls them on system sleep. The driver never enabled runtime PM, so suspend left the controller running and resume never re-initialised it. After some resumes its codec commands timed out (`azx_get_response timeout, switching to polling mode`) and HDMI and DisplayPort audio stayed degraded or silent until reboot; on NVIDIA's board resume took 81 seconds. The controller is now stopped and its link reset on suspend, and re-initialised on resume. `1030` already carried NVIDIA's `pm_ptr()` follow-up to this commit, which until now only had the system sleep callbacks to wrap.
- `1032` is Cirrus' "ASoC: cs35l56: Wait for firmware timer expiry before system suspend", taken from the list (Mark Brown's bot reported it applied to `broonie/sound` for-7.3, but it is in neither linux-next nor 7.3-rc6). On 7.2.8 it applies as posted. CS35L56 firmware older than 3.13.7 does not allow a SoundWire bus reset within 250 ms of starting a firmware timer, and system suspend could reset the bus inside that window. The ProArt P14's amplifiers run 3.13.4. The first amplifier to suspend now waits for the timer to expire, once for all of them.

The rt712-sdca PLL2 fix (d56fe35c1bce, NVIDIA's a241cbc5dd92) was `1033` on 7.2.5. It is now part of Omarchy's shared ASoC fixes (`0525-asoc-fixes-3.patch`), so the package no longer carries it.

Patches 1070–1082 make USB4 and Thunderbolt work. The N1x host routers (`\_SB.UBF0..2`, `NVDA8100`, one per USB-C port) are ACPI platform devices rather than PCI NHIs, the firmware hands USB4 to the OS, and it has no connection manager of its own. Without these patches nothing bound them, so PCIe-tunnelled devices (docks, 10G adapters, eGPUs) never appeared, and USB4 docks fell back to USB-C alt modes.

- `1070` reverts NVIDIA's SAUCE that disabled USB4 through a vendor `_DSM`. The ASUS EC doesn't implement that `_DSM`, so the revert also removes a 2 s stall.
- `1071` has `ucsi_acpi` query the `_DSM` functions before using them, as the ACPI spec asks. The ProArt P14 EC opens its UCSI service on that query, and without it every boot logged `PPM init failed` and `/sys/class/typec` stayed empty.
- `1072` adds `power_wrap_drv.usb4_release=`. NVIDIA's power_wrap releases the host routers' SSPM resources once xHCI is up. After that the SSPM stops answering for them, and a later power request hangs it and resets the SoC. `1076` reports whether the release ran, so the driver can refuse to probe.
- `1073`–`1075` let the Thunderbolt core run on a host interface that is not a PCI device, building on 7.2's non-PCI NHI groundwork. On 7.2.8 the PCI glue keeps Omarchy's shutdown host reset (`nhi_pci_do_remove()`) and hands the rest of the teardown to `nhi_remove()`.
- `1077` is the glue driver itself, `thunderbolt_platform` (`CONFIG_USB4_PLATFORM_NHI`). It maps the host interface, powers it through power_wrap, and services the rings from the one wired level interrupt.
- `1078` fixes PCI bus numbering below a hot-added switch. Without it, `pci=hpbussize`, which the unconfigured tunnel root ports need, let a dock's first downstream port take every bus number, so the ports after it (on a CalDigit TS4, the Ethernet controller) were never enumerated.
- `1079` turns off CL states on the N1x host router's links. With them on, a monitor behind a DisplayPort tunnel failed to sync to its first link training and kept dropping out, so a dock's display usually stayed dark at boot and often on hotplug.
- `1080` keeps the routers out of USB4 sleep during suspend. A router only leaves that sleep through the reset it gets when its host interface loses power, which never happens here, so a port with a device attached stopped answering after resume.
- `1081` stops the driver powering the routers down when it is unbound. The SSPM can turn a router off, but turning it back on does not restore what the boot firmware set up, so the router stayed dead until the next boot.
- `1082` offers the N1x host router's DP IN adapters again when a monitor is plugged in. The connection manager drops a DP IN adapter whose tunnel fails DPRX negotiation until the adapter reports a hotplug, which the N1x's never do, so after one failure every display behind a dock on that port stayed black until reboot.

`1083` (2542613815) and `1084` (a2463e2394) are UCSI core fixes from linux-next, which `ucsi_acpi` uses for the USB-C ports. `1083` retries `ucsi_init()` when the EC rejects an early command or reports no connectors, as it already did for a missing role switch; before, one bad answer while the EC was still starting left `/sys/class/typec` empty for the whole boot. `1084` retries re-enabling UCSI notifications on resume, up to five times 500 ms apart; an EC that was still busy when the system woke otherwise left the ports deaf to plug events until reboot. On 7.2.8, which has the upstream workqueue rename (`system_dfl_long_wq`) and `ucsi_debugfs_unregister()`, both apply as they are in linux-next.

Patches 1090–1095 are NVIDIA's SAUCE from `Ubuntu-nvidia-7.0-7.0.0-1022.23_24.04.1`, which has the MT8901 controllers report their sleep states to the SSPM through power_wrap. On this platform the ACPI power resources are empty stubs, so a device only powers down in suspend once the SSPM is told it reached D3:

- `1090` (a255ee68ee85) makes `sspm_ci` tell a request that was never sent (`-EBUSY`) from one whose completion is unknown (`-ETIMEDOUT`).
- `1091` (fff35e933484) gates a whole PCIe host through power_wrap once every root port on it is in D3cold and none is set to wake the system.
- `1092` (053c2c7902c3) adds `xhci-mtk-v2` (`CONFIG_USB_XHCI_MTK_V2`) for the NVDA8000/NVDA8001 controllers, which reports their D3 and D0 in system suspend. It is rebased onto 7.2's `xhci_dbc_remove()`, which takes `enable_mutex`. `1093` (522542575927) adds the 2 ms delay before CRS that these controllers need on resume.
- `1094` (a6a609d1b7ff) and `1095` (03b41c9a041a) bind SPI over ACPI and have the SPI and I2C controllers report D3 in suspend.

`1096` (0f0aeba49253, NVIDIA PR #635, merged after 1022.23) clears the MT8901 EINT event mask for every interrupt armed as a wake source, not only the ACPI event line, so the SPM sees keyboard and touchpad wakes. Without it the platform's deepest sleep state could only be left by the ACPI event line, and a key press did not wake it.

NVIDIA's companion watchdog rework (280db0e8cf30) is not carried; it replaces the sbsa_gwdt sleep patch already in `1020` and needs the upstream `early_enable` parameter (1376a013a1, linux-next) first.

The USB4 driver binds only with `power_wrap_drv.usb4_release=0` on the command line. Omarchy sets that together with the PCI hotplug padding.

SAUCE that was left out:

- `serial: 8250_mtk: Add ACPI support`, the MT7925 CSA patch and the four cpufreq QoS patches are superseded by 7.2
- the ACPI `_LPI` hierarchical idle series (SAUCE 0039–0054 and 0067–0069) is deferred to the 7.3 port (see [`UPGRADING-7.3.md`](UPGRADING-7.3.md)). Without it, CPU idle uses the flat LPI states only

Patches 1100–1104 are for the ASUS ProArt P14 (H7407BA) keyboard, 0B05:4B42: the upstream Zenbook A16 support (Fn keys), a keyboard backlight LED for systems without asus-wmi, host-controlled Fn-lock, turning off the keyboard's OOBE mode, which otherwise keeps fading the backlight in and out, and turning the backlight off for sleep. 7.2.6 brought the upstream hid-asus rework that moves the backlight and Fn-lock writes onto one worker (47669bec44fe), so `1101`, `1102` and `1104` were rebased onto it: the LED class device now lives in the driver data, Fn-lock goes through `asus_kbd_fn_lock_set()`, and the use-after-free fix `1101` used to carry is upstream.

## Snapdragon laptops

Since `7.2.8-2` this is also the kernel for the Snapdragon X laptops. Their drivers were already on in the config.

The laptops get no device tree from their firmware, so the package builds the Windows-on-ARM families' trees (`x1*`, `hamoa*`, `glymur*`, `sc8280xp*`) and installs them under `/boot/dtbs/linux-omarchy-n1x/qcom`. They sit under the package's name so that no file is shared with Arch Linux ARM's `linux-aarch64`, which keeps its own in `/boot/dtbs`. Omarchy's Snapdragon setup lists them for the UKI.

Two differences from Arch Linux ARM's kernel matter on these laptops. Omarchy's Snapdragon setup handles both, so the config stays as the N1x needs it.

- The X1 pin control, interconnect, PMIC and bus drivers are modules here and built in there. mkinitcpio's hooks only pick storage, input and display drivers, so the setup names them for the initramfs.
- `IOMMU_DEFAULT_PASSTHROUGH` is on here. Under it the Yoga Slim 7x's keyboard, touchpad and touchscreen read back empty HID descriptors and never appear, so the setup boots with `iommu.passthrough=0`.

## Config

`config.aarch64` started from NVIDIA's `arm64-nvidia` annotations for the 1021.21 tree, went through `olddefconfig` on 7.2.5, and then had `linux-omarchy`'s behavioral choices applied (preemption, LSM list, zswap and zram defaults, THP, built-in Btrfs, schedutil, I/O schedulers, binder off, no Canonical trusted keys). It sets `linux-omarchy-bore`'s scheduler options too: `SCHED_BORE=y`, `MIN_BASE_SLICE_NS=2000000` and `MQ_IOSCHED_ADIOS=m`.

On 7.2.8 it went through `olddefconfig` again and took the architecture-independent changes `linux-omarchy` made since 7.2.5-6: `RESET_ATTACK_MITIGATION` and `SWIOTLB_DYNAMIC` off, `IMA_WRITE_POLICY` and `IMA_READ_POLICY` on. New symbols kept their defaults (`ACPI_BATTERY_HOOKS=y`; the new hwmon, haptics and camera drivers stay off). `ARCH_MMAP_RND_BITS` stays at the arm64 maximum of 33: `linux-omarchy` moved x86's value to that architecture's default, which says nothing about arm64.

`CONFIG_KEXEC_HANDOVER_ENABLE_DEFAULT` is off since `15`, as in NVIDIA's 63bbd5f0d (LP 2168816). With it on, kexec handover set aside its scratch area as CMA on every boot, about 2.1 GiB on the ProArt P14, and long-term page pins (CUDA host-pinned memory, RDMA registrations) could fail with ENOMEM under memory pressure because pinned pages cannot stay in CMA. Omarchy does not use kexec handover; `kho=on` still turns it on.

## Building

The package is large and hardware-specific, so unscoped repository builds skip it. Build it explicitly, natively on aarch64 where possible:

```bash
bin/repo build --arch aarch64 --package linux-omarchy-n1x
```

The build produces `Image`, modules and the Snapdragon laptops' device trees; N1x boots through ACPI and needs none. It installs the raw arm64 `Image` as `vmlinuz` for Limine's aarch64 Linux protocol.

## Validation

7.2.8-1 was built natively on the ProArt P14 (2026-10-09), and the NVIDIA open modules 615.78.08 (with our patches) and `acpi_call` compile against it. It has not been booted yet.

7.2.8-1 with the device trees added, built in an Arch Linux ARM container, on a Lenovo Yoga Slim 7x (2026-10-11), installed beside `linux-aarch64` with the drivers above in the initramfs and `iommu.passthrough=0`. LUKS unlock at Plymouth with the built-in keyboard, the panel at 2944x1840 with the Adreno firmware, touchpad and touchscreen, Wi-Fi and Bluetooth, both DSPs, the sound card and the battery reading all work, with no failed units. That boot's UKI carried Arch Linux ARM's device trees. Without `iommu.passthrough=0` the same kernel reached the password prompt with no keyboard. An installer image on this kernel, with the package's own device trees in its live UKI, installs unattended in a VM. 7.2.8-2 has not been booted on an N1x.

7.2.5-6.5 on the ASUS ProArt P14 H7407BA with `nvidia-open-dkms` 615.71.09 (2026-10-02): LUKS unlock at Plymouth, internal display and brightness, CUDA, keyboard (Fn keys, backlight, Fn-lock), touchpad, speakers, headphones and microphones, battery and AC, Wi-Fi and Bluetooth, webcam, 122 GiB of RAM with `efi_reclaim_reserved=` (the reclaimed ranges kept a written pattern through display, 16 GiB of CUDA work and suspend-to-idle), suspend-to-idle.

7.2.5-6.8 on the same machine (2026-10-03): UCSI and the three USB-C ports' Type-C class devices; a CalDigit TS4 on each of the three USB4 ports with a 40 Gb/s link, its USB3 and 2.5 GbE (`igc`) and a 4K 240 Hz display through its DisplayPort tunnel, at boot and on hotplug; HDMI out; the UHS-II SD reader. Omarchy writes the USB4 kernel options (`power_wrap_drv.usb4_release=0 pci=hpbussize=0x80,hpmmiosize=32M,hpmmioprefsize=32G`) from `install/hardware/n1x.sh`, and a dock or adapter is approved once with `boltctl enroll --policy auto`.

Not yet validated: USB4 devices across suspend (patches 1080 and 1081), lid-driven suspend and battery drain while suspended, warm reboot loops. The firmware's `deep` sleep returns at once, so Omarchy defaults these machines to `s2idle`.
