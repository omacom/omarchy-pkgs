# Porting linux-omarchy-n1x to 7.3

Notes for moving this package from 7.2.8 to 7.3, written while rebasing it from 7.2.5 to 7.2.8 (2026-10-09). The upstream state below is mainline v7.3-rc6 (a90ee4305c4, 2026-10-04), mainline master at af32da41b0 (2026-10-09, the net-7.3-rc7 merge) and linux-next next-20261008 (aac26bee2287). Re-check every "not upstream" and "only in linux-next" claim against the final 7.3 tag before relying on it.

## What to expect

- A trial rebase of all 118 N1x commits of 7.2.8-1 onto plain v7.3-rc6, without Omarchy's shared patches, went through git's three-way merge for all but two: `1100` drops out because 2061075360 is in 7.3-rc1, and `1094` conflicts with 06f9d950cb ("spi: mt65xx: use modern PM macros", 7.3-rc1). With `config.aarch64` run through `olddefconfig` on that tree, every directory the N1x patches touch (`drivers/{pinctrl,soc/mediatek,thunderbolt,usb/host,usb/typec,hid,i2c/busses,soundwire,platform/arm64,acpi,firmware,pci,iommu,cpuidle,pmdomain,cpufreq,watchdog,irqchip,gpio}`, `sound/{soc/mediatek,soc/codecs,soc/sdw_utils,soc/sof,hda}`, `kernel/sched`) compiled without errors and with no new warnings in N1x code. That was an object build only (no vmlinux link, no modpost), without Omarchy's 7.3 shared patches, and nothing was booted. `PINCTRL_MT8901`, `EINT_MTK` and `PINCTRL_MTK_PARIS` stayed `=y` there.
- Much of what 7.3 changes around these patches already sits under them on 7.2.8, through Omarchy's shared patch set or 7.2.y stable:
  - `0210-pm-updates.patch` carries the 7.3-rc1 power management pull, including Rafael Wysocki's `_LPI` parsing rework (d06c12bebf98..67fcf679c808). `1020` and `1021` already apply on top of it.
  - `0511-asoc-updates.patch` carries the CS35L56 move to the SoundWire core's interrupt (243ca1fb53, ee1811eacd, a075fef187), the CS35L62 additions, and the sdw_utils `ch_map` changes (4d855d7475, 290845e151, b5b00a5786). 7.2.7 stable brought the CS35L56 fixes 888162dabf, 1d80a4792f and 883e78c9e6; Omarchy's later ASoC fix patches (`0523`, `0525`) bring fbf2c660ba and the rt712-sdca PLL2 fix d56fe35c1bce (the old `1033`).
  - `0601`, `0602` and `0606` carry Sven Peter's DPRX and teardown fixes from 7.3-rc6 (0b457c6733, c222f80be5, 419fa32fa5, 1fd1f67c94, 12f5d8b85a) and the Anker CL-state quirk 395e9f2967. `1082` already runs on them.
  - `0603-usb-updates.patch` carries the workqueue rename (90cd20729640, `system_dfl_long_wq`) and `ucsi_debugfs_unregister()`, so `1083` and `1084` are already the linux-next versions.
  - 7.2.6 stable brought the hid-asus worker rework 47669bec44fe (so `1101`, `1102` and `1104` are already rebased onto it) and the MediaTek EINT teardown 88292b7103 and `devm_gpiochip_add_data()` 9c650317ba.
- So the 7.3 port mostly means: take the 7.3 shared set from `linux-omarchy-eevdf` when it exists, rebase the N1x commits onto it with the method below, rework `1094`, drop `1100`, and re-test the platform, because the parts 7.3 changes underneath (MediaTek pinctrl as modules, SPI PM macros, arm_ffa shutdown, CS35L56 feedback ports) are what this machine runs on.

## Method that worked for 7.2.5 to 7.2.8

The patch files are `git format-patch` mbox series, so a three-way rebase in a scratch repository handles most context changes:

1. Import the old base: `tar xf linux-7.2.8.tar.xz`, `git init`, commit it, apply the old shared patches with `patch -Np1 --fuzz=0` and commit that as one commit (`shared-old`).
2. `git am --keep-cr` every N1x patch file in `source=()` order onto it, and record how many mails each file holds (1000 has 18, 1010 18, 1020 12, 1030 32, 1040 3, the rest 1).
3. Import the new base the same way as an unrelated root (new tarball plus the new shared patches, one commit, `shared-new`), for example with `git fetch ../new-tree master:shared-new`.
4. `git rebase --onto shared-new shared-old n1x`. Resolve conflicts; commits whose change is already in the new base are dropped as empty (that is how `1033` went).
5. Regenerate only what needs it: for each mail, check it out at its position, try the original mail with `patch -Np1 --fuzz=0`, and replace it with `git format-patch -1 --stdout <new commit>` only if it fails or its content or message changed. Untouched mails stay byte-identical, which keeps the package diff reviewable.
6. Apply the new series to a clean `shared-new` tree in `source=()` order and compare the result with the rebased branch; only `.orig` files may differ.
7. Note every adaptation in the commit message as `[omarchy: ...]`, keeping the original author and text.

The scratch repositories from the 7.2.8 port are in `~/Work/kernel-n1x/port-7.2.8/` (`rb` holds `old-n1x`, `new-n1x`, and `try73`, the trial rebase onto v7.3-rc6; `regen.py` is step 5).

## Per patch

"In 7.3" means present in v7.3-rc6 unless stated. "next" means only in linux-next, so 7.4 material unless it is sent as a fix.

### 1000-n1x-mediatek-platform.patch (18 NVIDIA SAUCE mails)

| Mail | Upstream | 7.3 notes |
|---|---|---|
| xhci-plat: USB3 bulk-stream U1/U2 quirk; xhci-hub: MT89xx PORTLI | Not upstream | 6d45e9556d (multi bit-field macros, 7.3-rc1) touches `xhci-mtk.c` cosmetically; `xhci.c` and `xhci-ring.c` have 8 and 13 upstream changes since 7.2, all merged cleanly in the trial. |
| pinctrl: gpio-range record, ACPI support, MT8901 driver, ACPI wake EINT, bus-hold bias | Not upstream. The only MT8901 posting is Lei Xue's pinctrl v1 ([patchew](https://patchew.org/linux/20251125023639.2416546-1-lei.xue@mediatek.com/), 2025-11-25, no replies) | 7.3-rc1 makes the MediaTek pinctrl drivers buildable as modules: 5f30668104 (all SoC drivers tristate), dab3c7afde (common code as modules), e3b4295e0d, plus aef612f013 (IRQ trigger mask helpers). `PINCTRL_MT8901` is still `bool` with `arch_initcall()`; keep it built in (the keyboard and touchpad are HID-over-I2C behind its EINTs and LUKS needs the keyboard in the initramfs), but check that the `select`ed common parts (`PINCTRL_MTK_PARIS`, EINT) end up `=y` and that the symbols mt8901 uses from `mtk-eint.c` and `pinctrl-paris.c` are still visible when those are modules elsewhere. 88292b7103 and 9c650317ba are already in 7.2.6, which is why the EINT wake mail carries an `[omarchy:]` note. cbb91e55a9 (`eint->base` allocation type) is in next. |
| i2c: mediatek: ACPI/MT8901 and firmware-managed clocks | Not upstream | No upstream change to `i2c-mt65xx.c` since 7.2. |
| gpiolib: acpi: debounce warn-only wrapper | Not upstream | `include/linux/gpio/driver.h` has one change in next. |
| soc: mediatek: SSPM control interface, power_wrap (7 mails), UCSI USB4-disable `_DSM` | Not upstream; no posting | New files, no conflicts possible. The UCSI `_DSM` mail is reverted by `1070`; drop both together if NVIDIA ever drops it. |

### 1010-n1x-ffa-ec.patch (18 NVIDIA SAUCE mails)

Not upstream; there is no upstream driver for ARML0002 / DEN0077A ECs. 3bb3e80faf21 ("firmware: arm_ffa: Tear down driver during shutdown") is in 7.3-rc4, so 7.3 tears FF-A down at shutdown. The EC behind FF-A (battery, AC, lid, thermal, UCSI, the PEPD `_DSM`) may then be gone for anything that runs later in poweroff; NVIDIA validated that change only on Grace and Vera, and NVIDIA [PR #641](https://github.com/NVIDIA/NV-Kernels/pull/641) (2026-10-09) backports it for kexec on Vera. Test poweroff, reboot and lid/battery behaviour right before poweroff on 7.3. `drivers/acpi/scan.c` (this patch adds HIDs to `acpi_ignore_dep_ids[]`) has 19 upstream changes in 7.3 and 6 more in next, among them 2f4ddf2bd ("ACPI: scan: Stop calling acpi_bus_init_power() early") and 5636eebb7 ("ACPI: PM: Drop parent state update from acpi_device_get_power()"); after those, a device whose initial power state cannot be read logs "Initial power state undetermined, ACPI PM disabled". `drivers/acpi/battery.c` already has Omarchy's renamed battery hook API (`0803`/`0804`) on 7.2.8.

### 1011, 1012, 1013 (Dell XPS 16)

Ours, not upstream. `drivers/acpi/thermal.c` has two changes in next. Nothing in 7.3 conflicts.

### 1020-n1x-power.patch (12 NVIDIA SAUCE mails)

- GIC "allow unused SGIs" and io-pgtable-arm contiguous bit: NVIDIA backports, not upstream as such. `irq-gic-v3.c` has 3 changes in 7.3.
- `cppc_cpufreq.auto_sel_mode=`: no upstream equivalent; upstream exposes `auto_select` and `energy_performance_preference_val` in sysfs, and Omarchy's `omarchy-power-profiles-daemon` now drives CPPC from userspace. Sumit Gupta's "Preserve OSPM-set registers across hotplug and unload" v5 ([patchew](https://patchew.org/linux/20260916103820.1760297-1-sumitg@nvidia.com/)) is not in next. Christian Loehle's `_CPC` hardening (fb345025f1..4bcc60d326, next) needs a boot test on 7.4.
- sbsa_gwdt "stop the watchdog across the whole system-sleep transition" (9c77d37b679b): David Cemin posted it upstream on 2026-09-12 ([patchew](https://patchew.org/linux/20260912182107.1156221-1-dcemin@nvidia.com/)), no review yet. See the watchdog section below.
- pmdomain, cpuidle-psci, sched idle and processor_idle preparation (2c1fcccd3, 569979c16, c727f8ee3, 7f0e8a76c, 2a269ed56, 4c9888996, e0ed9272a): NVIDIA's groundwork for hierarchical LPI, not upstream. `drivers/pmdomain/core.c` has 7 changes in next. They already sit on the `_LPI` rework on 7.2.8.

### 1021-ACPI-processor_idle-let-LPI-states-freeze-the-tick-in-suspend-to-idle.patch

Ours, not posted. Still needed on 7.3: nothing upstream gives `_LPI` states an `->enter_s2idle`, so without it CLOCK_MONOTONIC runs through s2idle and systemd kills logind and journald for missed watchdog pings after three minutes of sleep. It already applies on top of Rafael's rework. If the hierarchical LPI series is ported, see the next section: `1021` has to move into its non-coordinated branch.

### 1030-n1x-audio.patch (32 NVIDIA SAUCE mails plus our signature fix)

Not upstream. MediaTek has not posted a SoundWire manager, MT8901 ASoC or SOF code anywhere. Only two generic pieces are on their way: 7c7df141dc ("ASoC: sdw_utils: clear stale RT711 device reference on exit", next; the same as the SAUCE mail here, so it drops on 7.4) and the hda-acpi runtime PM fix that `1031` carries. Things to recheck on 7.3:

- CS35L56 interrupts come from the SoundWire core since 243ca1fb53/ee1811eacd (already on 7.2.8 through `0511`). The amps' interrupt then depends on the MediaTek manager reporting peripheral alerts through `sdw_handle_slave_status()`. Check `/proc/interrupts` for the cs35l56 entries and that they count when the amps raise an alert (boot, firmware load, over-temperature).
- 4d855d7475 renamed `snd_soc_dai_link_ch_map.ch_mask` to `cpu_ch_mask` and 290845e151 sets `codec_ch_mask` for capture in the Intel-style sdw_utils path. The MT8901 machine driver (`mt8901-acp-sdw-legacy-mach.c`) builds its own `ch_maps` and sets only `cpu` and `codec`, so it builds, but compare its capture links with what `sof_sdw` now sets if amp feedback or microphones capture the wrong channels.
- Cirrus' "Use the correct SoundWire DP for feedback" (86c8360c97 "Add DAI for SDCA OT25 stream", 4b7f393a01 "sdw_utils: Switch CS35L56/57/62/63 to use OT25 DAI", merged as fb52d06345 in `broonie/sound` for-7.3; [patchew](https://patchew.org/linux/20261005155235.1386525-1-rf@opensource.cirrus.com/)) moves the amp feedback from DP3 to DP4. None of the three ids is in mainline master or next-20261008, so they may land in 7.3-rc7 or 7.4. When they do, the MT8901 machine entries for the CS35L56 (`mtk-sdw-mach.c`) and Omarchy's UCM capture path for the speaker feedback have to follow.
- The asoc_sdw_parse_sdw_endpoints() signature fix at the end of this file tracks sdw_utils; 7.2.8 already has a1332be2a070 and c97f0bf5f705 (its tidy-ups), and the 7.3 signatures are the same.
- UCM: NVIDIA's [alsa-ucm-conf#862](https://github.com/alsa-project/alsa-ucm-conf/pull/862) (open) adds `ucm2/conf.d/mt8901-soundwir/mt8901-soundwir.conf`, the file `omarchy-settings-dev` installs today, so Arch's alsa-ucm-conf would conflict with it once merged. Jaroslav Kysela asked on 2026-10-09 for a shorter driver name such as `mt8901-sdw` and questioned the component-string matching. If NVIDIA shortens `card->name` ("mt8901-soundwire", truncated to the 15-character driver name `mt8901-soundwir`), the kernel side of this patch and Omarchy's UCM directory move together. Either adopt #862 and keep only board overrides, or move Omarchy's dispatcher out of `conf.d`.

### 1031-ALSA-hda-acpi-add-runtime-PM-suspend-resume-to-the-ACPI-controller.patch

a41da0bb086e, in next (Takashi Iwai's tree), not in 7.3. Keep it on 7.3, drop it on 7.4. `1030`'s pm_ptr() follow-up depends on it.

### 1032-ASoC-cs35l56-Wait-for-firmware-timer-expiry-before-system-suspend.patch

Cirrus' posting ([patchew](https://patchew.org/linux/20260915102110.3276924-1-rf@opensource.cirrus.com/)). Mark Brown's bot reported it applied to `broonie/sound` for-7.3 as 7226c5c21f48, but that id is in neither the for-7.3 head f90f8afb61be, next-20261008 nor 7.3-rc6, so it was most likely dropped or rebased. Check `git log --grep='firmware timer expiry'` on the 7.3 tag; if it is not there, keep the patch (it applies as posted on 7.2.8 and should on 7.3). The ProArt P14's amps run firmware 3.13.4; the patch only matters below 3.13.7 (B0).

### 1040-n1x-gpu-iommu.patch (3 NVIDIA SAUCE mails)

Not upstream; no upstream identity/DMA default-domain quirk for the N1x iGPU. `arm-smmu-v3.c` has 14 changes in 7.3, all merged cleanly in the trial. Without it GSP does not boot and the screen stays black, so a boot test proves it.

### 1050, 1060

Ours. `efi-init.c` has two changes in next; nothing conflicts.

### 1070-1072, 1076 (UCSI and power_wrap USB4)

Ours. No upstream equivalent of `1071` (query the `_DSM` functions before use). `ucsi_acpi.c` gained only the Acer UCSI 1.2 quirk (8c51ea651d, 7.3-rc6).

### 1073-1077 (USB4 on a non-PCI host interface)

Ours, not posted. Upstream is converging on a different shape and these should follow before anything is sent:

- Sven Peter, "Initial USB4/Thunderbolt support for Apple M1/M2/M3 SoCs" v2 ([patchew](https://patchew.org/linux/20260906-b4-apple-soc-tbt-v2-0-1f80085f93fb@kernel.org/), 2026-09-06): optional `tb_nhi_ops` hooks (`ring_interrupt_active`, ring register accessors, `ring_interrupt_mask`, `ring_configure`, `add_links`), `QUIRK_NO_USB3_BW_ALLOC`, host DROM from the device, exports restricted to the `thunderbolt_apple` module, and `drivers/thunderbolt/apple.c`. Not in next yet. Our `1074` (one wired interrupt for all rings) and `1075` (exported `nhi_probe()`/`nhi_remove()`) should become `tb_nhi_ops` users once that lands, and `thunderbolt_platform` would look like `thunderbolt_apple`.
- Konrad Dybcio, "thunderbolt: Make PCIe NHI support opt-in" ([patchew](https://patchew.org/linux/20260915-topic-tbt._5Fpcie._5Foptional-v1-1-47c4a3d129bd@oss.qualcomm.com/), 2026-09-15): drops `depends on PCI` from `USB4` and adds `CONFIG_USB4_PCIE` / `thunderbolt_pcie`. If it lands, `1073` (check for a PCI NHI before treating it as one) mostly goes away and `config.aarch64` needs `USB4_PCIE` decided (the N1x has no PCI NHI, but USB4 docks still tunnel PCIe through the platform NHI; the option only covers the host interface).
- Mika Westerberg's ring polling and batching rework is in next (87045fbb80 "Allow batching of descriptors", 26e6e964d5 "Use shadow copy for ring interrupt mask", 85e5f54bb3, ea958a1907, 4d84caebab, de9d89b408). It rewrites the ring interrupt code `1074` changes, so 7.4 will conflict there.
- On 7.2.8, Omarchy's shared Thunderbolt fixes make PCI shutdown reset the host router (`nhi_pci_do_remove()`, `nhi->host_reset`) and `tb_stop()` assert DPR on Thunderbolt 3 devices. `nhi_probe()` now sets `nhi->host_reset` from the `host_reset` module parameter for every host interface, so `thunderbolt_platform`'s unbind and shutdown also reset downstream Thunderbolt 3 (not USB4) devices. That is upstream behaviour, but it is new for the N1x; check it with a Thunderbolt 3 device if one is around. Omarchy's delayed PCIe rescan after tunnel activation (`0605`, the same idea as Canonical's e04af32a5395, LP [2139572](https://bugs.launchpad.net/bugs/2139572)) skips non-PCI host interfaces, so it does nothing on the N1x.

### 1078-1082 (PCI bus numbers, N1x router quirks, DP IN retry)

Ours. `drivers/pci/probe.c` has 7 changes in next; recheck `1078` against them. The quirk table in `quirks.c` matches 7.3's layout (395e9f2967 added the Anker entry the same way). `1082` (offer the N1x DP IN adapters again after a DPRX failure) already runs on Sven Peter's DPRX teardown series ([patchew](https://patchew.org/linux/20260829-b4-tbt-fixes-v3-0-e1fab6ac54fe@kernel.org/), in 7.3-rc6 and in `0606` on 7.2.8). His fixes make sure a canceled DPRX read no longer touches a dead tunnel; they do not re-offer a DP IN adapter that never reports hotplug, so `1082` is still needed. Re-test the dock replug that produced "DP IN resource unavailable: DPRX negotiation failed" before dropping anything.

### 1083, 1084 (UCSI retries)

2542613815 and a2463e2394, in next (Greg's usb-next), not in 7.3. Keep on 7.3, drop on 7.4. On 7.2.8 they are already the upstream versions.

### 1090-1095 (NVIDIA 1022.23 device sleep SAUCE)

Not upstream (a255ee68ee85, fff35e933484, 053c2c7902c3, 522542575927, a6a609d1b7ff, 03b41c9a041a; LP [2167884](https://bugs.launchpad.net/bugs/2167884), [2167886](https://bugs.launchpad.net/bugs/2167886), [2167887](https://bugs.launchpad.net/bugs/2167887)).

- `1094` (spi-mt65xx ACPI and PM) conflicts with 06f9d950cb ("spi: mt65xx: use modern PM macros", 7.3-rc1): upstream dropped the `#ifdef CONFIG_PM_SLEEP` / `#ifdef CONFIG_PM` blocks and uses `SYSTEM_SLEEP_PM_OPS`/`RUNTIME_PM_OPS` with `.pm = pm_ptr(&mtk_spi_pm)`. Rework: remove the `#ifdef` guards around `mtk_spi_pwrap_resume()`, `mtk_spi_suspend_noirq()` and `mtk_spi_resume_noirq()`, drop the forward declaration of `mtk_spi_runtime_resume()` if it is no longer needed, and add `NOIRQ_SYSTEM_SLEEP_PM_OPS(mtk_spi_suspend_noirq, mtk_spi_resume_noirq)` to the 7.3 `mtk_spi_pm`. Keep the probe/remove ACPI hunks as they are.
- `1091` hooks `pci-driver.c`, `portdrv.c`, `pme.c` and `pciehp_core.c`; those have 3+5, 3+1, 0 and 0+3 changes (7.3 + next). The trial merged them; read the noirq paths again after the rebase.
- `1092`/`1093` (xhci-mtk-v2): `xhci.c`, `xhci-mem.c`, `xhci-hub.c` and `xhci-dbgtty.c` changed in 7.3 and merged cleanly; `1092` was backported onto 7.2's `xhci_dbc_remove()`, recheck that against 7.3.

### 1096-pinctrl-mt8901-sync-wake-EINT-event-mask.patch

NVIDIA PR #635 head 0f0aeba49253 (internal 1c829c26a421, LP [2170130](https://bugs.launchpad.net/bugs/2170130)); not upstream. Sits on `mtk-eint.c`, which 7.3 builds as a module elsewhere: check `mtk_eint_irq_set_wake()` still runs for the keyboard (EINT 42), touchpad (43) and touch panel (33) after the rebase. If NVIDIA publishes a tag after 1022.23, compare its version with ours.

### 1100-1104 (ASUS keyboard)

- `1100` (Zenbook A16 support) is 2061075360, in 7.3-rc1: drop it.
- `1101`-`1104` are ours and not posted. The hid-asus rework they sit on (47669bec44fe) is in 7.3; `hid-asus.c` has 7 changes in 7.3 and 2 in next (8099f9da59 is Omarchy's `0566`). Worth sending upstream: the LED class device without asus-wmi (`1101`), the Fn-lock quirk and `fnlock_default` (`1102`), the ProArt P14 OOBE match (`1103`) and the sleep backlight-off (`1104`).

## Hierarchical `_LPI` and the 7.3 `_LPI` rework

- 7.3-rc1 has Rafael Wysocki's `_LPI` rework, committed 2026-07-17 from d06c12bebf98 ("Rearrange acpi_processor_evaluate_lpi()") to 67fcf679c808 ("Add switch for strict _LPI processing"), including 291c2047e7 (ignore SYSTEMIO entry), d5c13047a1 (package sanity checks, also in 7.2.6), df0702bfb5 (unified debug) and c60e851f9c17 (moves `acpi_processor_extract_lpi_info()` to `acpi_processor.c`). 7.2.8-1 already has all of it through `0210-pm-updates.patch`. After the first 7.2.8 boot, confirm the flattened states did not change: `grep . /sys/devices/system/cpu/cpu0/cpuidle/state*/{name,latency,residency}` should show LPI-0..6 with exit latencies 0/170/574/574/967/573/966 and an `s2idle/` directory on LPI-1..6, as on 7.2.5.
- NVIDIA's hierarchical series is on their 7.0 trees only (shipped in 1021.21): upstream backports fcf148a21..142b4daf8 (15 commits, the same rework), the preparation we carry in `1020`, then 8d9c86eae, 049347ae2, d1df85480, 307399d2a, df024d961, 9851ea842, 4e25b1a1c, 4110ad3a9, 9fd6d088e, 734144f2f, d6e3d1c82, 9dc30d146, d4ea2ac17, ddc74731a and the follow-ups e21b69979 ([#599](https://github.com/NVIDIA/NV-Kernels/pull/599)), b3019e792 and 692eddf86 ([#601](https://github.com/NVIDIA/NV-Kernels/pull/601)). PRs [#586](https://github.com/NVIDIA/NV-Kernels/pull/586)/[#587](https://github.com/NVIDIA/NV-Kernels/pull/587), LP [2167301](https://bugs.launchpad.net/bugs/2167301). It has not been posted upstream. The author's testing was "on-top of a DGX Spark ... Pending: S2idle verification"; the only later validation was on Grace and Vera.
- Since the rework is already under us, the series could be ported onto 7.2.8 or 7.3 in NVIDIA's order. It was deliberately not done for 7.2.8.
- How it would interact with `1021`: NVIDIA's `acpi_processor_setup_lpi_states()` sets `->enter_s2idle` only in the coordinated case, and only on the deepest leaf state (`acpi_idle_lpi_enter_s2idle()`, which goes through `dev_pm_genpd_suspend_s2idle()` and lets the genpd governor pick the cluster, package and system states). When OS-initiated mode is not negotiated (`_OSC`, `9851ea842`) or the leaf domain is missing, it registers the flat states with no `->enter_s2idle` at all, which is exactly the bug `1021` fixes. So: keep `1021`'s assignment in the non-coordinated branch (FFH states with `i != 0`, `->enter_s2idle = acpi_idle_lpi_enter_direct`), and drop it for the coordinated leaf.
- What coordinated s2idle would change here: the genpd path can pick the deepest domain state, which on the ProArt P14 is Standby-DRIPS. Forcing DRIPS on 7.2.5 (LPI-1..4 disabled) measured 8.6-10 W asleep against 6.2 W for the LPI-4 s2idle we use, and it needed `1096` just to wake from a key press. Measure s2idle power with and without the series before shipping it, and keep a way to cap the domain state (NVIDIA's #601 genpd debugfs disable, or `cpuidle` state disable).
- The series' review found a suspend deadlock ("suspend flushes `kacpi_notify_wq` while holding `system_transition_mutex`, but the notify-driven LPI rebuild waits for that mutex"), fixed before merge as "Serialize and recover LPI topology updates" (9dc30d146). Acknowledged but unfixed items: shared-domain latency recompute after CPU removal, PSCI rejection accounting for every selected domain, RCU-idle bookkeeping in the disabled-state fallback, parent power-off retry on re-enable.

## sbsa_gwdt

- We carry NVIDIA's 9c77d37b679b (stop the watchdog across the whole system-sleep transition, PM notifier) in `1020`.
- Not carried: 280db0e8cf30 ("park the watchdog around system sleep on MediaTek implementations", [#627](https://github.com/NVIDIA/NV-Kernels/pull/627)/[#628](https://github.com/NVIDIA/NV-Kernels/pull/628), LP [2169002](https://bugs.launchpad.net/bugs/2169002), in 1022.23) and [#632](https://github.com/NVIDIA/NV-Kernels/pull/632)/[#633](https://github.com/NVIDIA/NV-Kernels/pull/633) ("stop ping worker during system sleep", head 0fa2e333e898, merged internally as ca1f359ffea2 / 43f2507f37ed, `Fixes: 280db0e8cf30`, not in a public tag yet). 280db0e8cf30 replaces 9c77d37b679b and builds on the `early_enable` parameter: MediaTek's Zexin Wang, [v4](https://patch.msgid.link/20260817023838.6459-1-ot_zexin.wang@mediatek.com), NVIDIA's 34febda9ea74 cherry-picked from linux-next 11f93e639d51, which is 1376a013a1 in next-20261008. It is not in 7.3, so a 7.3 port needs 1376a013a1 first, then 280db0e8cf30 instead of 9c77d37b679b, then #632.
- Why it matters: MediaTek's SBSA watchdog ignores WCS.EN in its compare logic and the firmware re-enables it after WFI, so a watchdog refreshed shortly before sleep can reset the machine during or just after s2idle. On this install the watchdog is inactive (`watchdog0` inactive, `RuntimeWatchdogUSec=0`), so none of the three changes behaviour today. It becomes urgent if Omarchy ever sets `RuntimeWatchdogSec` or `sbsa_gwdt.early_enable=1` (Canonical's RTX Spark knobs do).

## arm64 s2idle, NVMe and pending ACPI s2idle work

- Since 7602c0ec0bbf ("firmware: psci: Set pm_set_resume/suspend_via_firmware() for SYSTEM_SUSPEND", v7.1), `platform_suspend_begin()` calls `psci_system_suspend_begin()` for s2idle too (arm64 has no `s2idle_ops`), so `pm_suspend_via_firmware()` is true during s2idle. NVMe therefore takes the full shutdown and D3 path (`pci_suspend_retains_context()` is false) instead of staying in D0 with APST, and the TPM sends TPM2_Shutdown. That probably helps the N1x: the NVMe root port can reach D3cold and `1091` can gate that PCIe host. NVIDIA's 7.0 kernels do not have it.
- Pending, not in next-20261008: Ovidiu Panait, "PM: suspend: Do not call suspend_ops->begin()/end() for s2idle" ([patchew](https://patchew.org/linux/20261005111157.17256-1-ovidiu.panait.rb@renesas.com/), 2026-10-05), and Riwen Lu, "ACPI: PM: Make s2idle available on all ACPI platforms with suspend support" v6 ([patchew](https://patchew.org/linux/20261002080703.77402-1-luriwen@kylinos.cn/), 2026-10-02) with "Drop unused sleep_no_lps0 define" ([patchew](https://patchew.org/linux/20261008025152.153073-1-luriwen@kylinos.cn/)). Either flips the above: NVMe goes back to D0 plus APST in s2idle and the NVMe host stops gating. Riwen Lu's adds `acpi_s2idle_ops` (scan lock in `begin`, SCI and `ACPI_STATE_S0` wake device enabling) but still no LPS0 or Modern Standby `_DSM` for arm64. When either lands, check which PCIe hosts `1091` gates (dynamic debug below) and re-measure sleep power.
- Maulik Shah's "pmdomain: Support system-suspend-only domain idle states" ([patchew](https://patchew.org/linux/20261005-s2idle._5Fstate-v1-0-3c402c66f388@oss.qualcomm.com/)) is DT-only as posted; conceptually it is how DRIPS could be limited to s2idle.
- In next for 7.4: 33392343c (DPM watchdog for prepare/late/early/noirq/complete; diagnostic, not the notifier chain).

## Known open items (not fixed by any patch here)

- Sleep power: about 6.2 W in s2idle on 7.2.5-14 (25 min, package PGKLL 99%), against 7.2-7.4 W before the 1022.23 device sleep patches. Screen-off idle awake is about the same, so the remaining draw is platform always-on.
- The GPU and memory never power down: the SPM requester records (`~/Work/n1x-display/s2idle/spm-blockers.py`) show IGPU, HFRP_HDA, HFRP_DLA, ADSPSYS and VADSYS holding DDREN, so DRAM never reaches self-refresh. NVIDIA's driver reports S0ix unsupported (no video memory self-refresh or GC-off), and GPU rail gating needs a device-tree power domain the ACPI N1x does not have.
- DRIPS: the firmware only reports DRIPS residency when LPI-1..4 are disabled, and then the battery drains faster (8.6-10 W). `PEPD.ELST`/MPEL, the Microsoft Modern Standby `_DSM` (functions 3/7/5 and 6/8/4, tried by hand with no effect) and F-state notifications (`mtk_pwrap_com_idle()`, no callers) have no kernel user anywhere.
- Pre-freeze stall: 82-83 s, and once 14 min, between `PM: suspend entry` and `Freezing user space processes`. Seen only with LPI-1..4 disabled or `deep`, and in the first suspends on 7.2.5-11; not the PM notifier chain on the instrumented runs. `n1x-stall-catcher.service` dumps stacks and panics into pstore if it happens again.
- `deep` (PSCI SYSTEM_SUSPEND) returns at once on the ProArt P14 and the XPS 16, so Omarchy defaults to `s2idle`.
- The ACPI TAD alarms and the RTC wakealarm do not wake the machine.

## Checklist

1. Wait for `linux-omarchy-eevdf` 7.3.x. Copy its shared patches, `.sig` files and the `_srcname`/source logic exactly; keep this package's `source_aarch64=(config.aarch64)`, the `make Image modules` build (no DTBs), the raw `Image` install and the headers section.
2. Rebase the N1x commits with the method above. Expected: drop `1100`; rework `1094`; drop `1031`, `1083`, `1084` only if 7.3 final has them (they are 7.4 material today); drop `1032` if the Cirrus patch landed; check `1030` against the OT25 feedback change.
3. Port `early_enable` (1376a013a1) and 280db0e8cf30 plus #632 only if the watchdog is going to run during sleep; otherwise leave `1020` as it is.
4. Do not port the hierarchical LPI series in the same release as the rebase. If it is ported later, carry `1021` into its non-coordinated branch and measure s2idle power with it.
5. `make ARCH=arm64 olddefconfig` with `config.aarch64` on the patched tree, review the diff, and keep: `CONFIG_USB_XHCI_MTK_V2=m`, `CONFIG_USB4_PLATFORM_NHI=m`, `CONFIG_KEXEC_HANDOVER_ENABLE_DEFAULT` off, `CONFIG_PINCTRL_MT8901=y`, `CONFIG_EFI_ZBOOT=y` (the package installs the raw `Image` anyway), `CONFIG_ARM64_4K_PAGES=y` (NVIDIA's driver mis-maps on 64K pages, open-gpu-kernel-modules #1269). Decide `USB4_PCIE` if Konrad Dybcio's patch landed. Take `linux-omarchy`'s new architecture-independent choices.
6. `pkgver=7.3.x`, `pkgrel=1`; update the README's `pkgrel` paragraph and the "same ... as linux-omarchy" line; `updpkgsums`; `makepkg --verifysource` with the keys in `keys/pgp/` imported into a throwaway `GNUPGHOME`.
7. Build natively in a fresh directory (`nice -n 10 makepkg -f --noconfirm`, 25-45 minutes on the ProArt P14 depending on what else runs), check `make -s kernelrelease`, and compare warnings with the previous build log.
8. Build the NVIDIA open modules against the new tree (`make -j20 modules SYSSRC=<build>/src/linux-7.3.x IGNORE_PREEMPT_RT_PRESENCE=1` in a copy of `NVIDIA-kernel-module-source-<version>`). 615.78.08 already has the 7.3 conftests (`atomic_create_state` hooks, the new `dmem_cgroup_register_region()` signature).

## Verification after the first boot

Run these on the ProArt P14 (and the XPS 16 where it applies) before calling the port good. The tools are in `~/Work/n1x-display/s2idle/`; `SUSPEND.md` there has the history.

- Boot: LUKS prompt at Plymouth with the internal keyboard, internal display and brightness, CUDA (`nvidia-smi`), 122 GiB with `efi_reclaim_reserved=`.
- CPU idle: `grep . /sys/devices/system/cpu/cpu0/cpuidle/state*/name` lists LPI-0..6 with the old latencies, and `/sys/devices/system/cpu/cpu0/cpuidle/state4/s2idle/usage` exists.
- s2idle and the clock (`1021`): suspend for more than three minutes, then `cat /sys/devices/system/cpu/cpu0/cpuidle/state4/s2idle/usage` has gone up, `journalctl -b | grep -i 'Watchdog timeout'` is empty, logind kept the session, Wi-Fi reassociated, and the kernel's monotonic clock advanced only a few seconds across the sleep (compare `[ time ]` stamps of `PM: suspend entry` and `PM: suspend exit` with the wall clock).
- Sleep power: `s2idle/s2idle-test.sh 1500 <label>` on battery; expect about 6.2 W and package PGKLL near 99%. A short run reads about 0.6 W high; compare like with like.
- Device sleep (`1090`-`1095`): `journalctl -k -b | grep 'ip-sleep'` shows `ip-sleep 1` then `ip-sleep 0` for NVDA8000:00/01/02/04 and NVDA8001:00 on every suspend. For the SSPM requests, enable dynamic debug before a suspend (`echo 'file power_wrap.c +p; file pci-mtk-pwrap.c +p; file i2c-mt65xx.c +p; file spi-mt65xx.c +p' | sudo tee /sys/kernel/debug/dynamic_debug/control`) and check the `scmi payload` lines for USB0/1/2/4/5, I2C0-6 and the five PCIe hosts (dev ids 0x39/0x3c/0x3e/0x3f/0x40, `sys_trans` 1) going to D3 and back to D0; no `pwrap D3 failed`.
- Wake sources (`1096`): a key press and the touchpad wake the machine; `cat /sys/power/pm_wakeup_irq` after a key wake reports 90.
- USB4 (`1070`-`1082`): with `power_wrap_drv.usb4_release=0 pci=hpbussize=0x80,hpmmiosize=32M,hpmmioprefsize=32G`, a CalDigit TS4 on each of the three ports links at 40 Gb/s (`boltctl list`), its USB3, 2.5 GbE (`igc`) and DisplayPort tunnel work at boot and on hotplug, and a dock replug after a missed monitor HPD brings the display back (no lasting "DPRX negotiation failed"). Then suspend with the dock attached and check the port still answers after resume (`1080`/`1081`, never validated on 7.2.5).
- UCSI (`1071`, `1083`, `1084`): `/sys/class/typec/port0..2` exist on every boot (no `PPM init failed`), and plug events still arrive after resume.
- Audio (`1030`-`1032`, `1060`): speakers (the amps load `cs35l56-b0-dsp1-misc-104333a1-spkid0*`), headphones, microphones; HDMI/DP audio after several suspend cycles with no `azx_get_response timeout` (`1031`); the CS35L56 entries in `/proc/interrupts`; no SoundWire bus errors around suspend (`1032`).
- Keyboard (`1101`-`1104`): `asus::kbd_backlight` exists and cycles with the backlight key, Fn+Esc toggles Fn-lock and `fnlock_default=` is honoured, the backlight does not fade by itself (OOBE off), it goes dark in suspend and comes back after resume.
- Shutdown and reboot: battery and AC reported up to poweroff, no hang or EC errors at poweroff (arm_ffa teardown, 3bb3e80faf21), warm reboot loops.
- Dell XPS 16 (`1011`-`1013`): battery status from EC RAM, no 600-1245 °C thermal zones, mic-mute hotkey and LED.

## References

- NVIDIA kernels: [NV-Kernels](https://github.com/NVIDIA/NV-Kernels) (branches `24.04_linux-nvidia-7.0-next`, `26.04_linux-nvidia`; our SAUCE base `Ubuntu-nvidia-7.0-7.0.0-1021.21_24.04.1` dd99802c8b0c and 1022.23 2234cd7f8f8a), PRs [#586](https://github.com/NVIDIA/NV-Kernels/pull/586), [#599](https://github.com/NVIDIA/NV-Kernels/pull/599), [#601](https://github.com/NVIDIA/NV-Kernels/pull/601), [#627](https://github.com/NVIDIA/NV-Kernels/pull/627), [#632](https://github.com/NVIDIA/NV-Kernels/pull/632), [#635](https://github.com/NVIDIA/NV-Kernels/pull/635), [#641](https://github.com/NVIDIA/NV-Kernels/pull/641).
- Launchpad: [2167235](https://bugs.launchpad.net/bugs/2167235) (hda-acpi), [2167301](https://bugs.launchpad.net/bugs/2167301) (hierarchical LPI), [2168816](https://bugs.launchpad.net/bugs/2168816) (KHO), [2169002](https://bugs.launchpad.net/bugs/2169002) (sbsa_gwdt), [2170130](https://bugs.launchpad.net/bugs/2170130) (EINT wake), [2167884](https://bugs.launchpad.net/bugs/2167884), [2167886](https://bugs.launchpad.net/bugs/2167886), [2167887](https://bugs.launchpad.net/bugs/2167887) (1022.23 device sleep).
- Upstream postings: [Apple USB4 v2](https://patchew.org/linux/20260906-b4-apple-soc-tbt-v2-0-1f80085f93fb@kernel.org/), [Thunderbolt DPRX fixes v3](https://patchew.org/linux/20260829-b4-tbt-fixes-v3-0-e1fab6ac54fe@kernel.org/), [USB4_PCIE opt-in](https://patchew.org/linux/20260915-topic-tbt._5Fpcie._5Foptional-v1-1-47c4a3d129bd@oss.qualcomm.com/), [CS35L56 timer expiry](https://patchew.org/linux/20260915102110.3276924-1-rf@opensource.cirrus.com/), [CS35L56 OT25 feedback](https://patchew.org/linux/20261005155235.1386525-1-rf@opensource.cirrus.com/), [hda-acpi runtime PM](https://lore.kernel.org/r/20260912182120.1156356-1-dcemin@nvidia.com), [sbsa_gwdt early_enable v4](https://patch.msgid.link/20260817023838.6459-1-ot_zexin.wang@mediatek.com), [sbsa_gwdt sleep](https://patchew.org/linux/20260912182107.1156221-1-dcemin@nvidia.com/), [arm_ffa shutdown](https://lore.kernel.org/all/20260901131112.3437516-1-sudeep.holla@kernel.org/), [Ovidiu Panait s2idle begin/end](https://patchew.org/linux/20261005111157.17256-1-ovidiu.panait.rb@renesas.com/), [Riwen Lu ACPI s2idle v6](https://patchew.org/linux/20261002080703.77402-1-luriwen@kylinos.cn/), [Maulik Shah s2idle domain states](https://patchew.org/linux/20261005-s2idle._5Fstate-v1-0-3c402c66f388@oss.qualcomm.com/), [CPPC OSPM registers v5](https://patchew.org/linux/20260916103820.1760297-1-sumitg@nvidia.com/), [MT8901 pinctrl v1](https://patchew.org/linux/20251125023639.2416546-1-lei.xue@mediatek.com/).
- Mainline commits: [7602c0ec0bbf](https://github.com/torvalds/linux/commit/7602c0ec0bbf) (PSCI suspend_via_firmware), [67fcf679c808](https://github.com/torvalds/linux/commit/67fcf679c808) (strict `_LPI`), [3bb3e80faf21](https://github.com/torvalds/linux/commit/3bb3e80faf21) (arm_ffa shutdown), [2061075360](https://github.com/torvalds/linux/commit/2061075360) (Zenbook A16 keyboard), [06f9d950cb](https://github.com/torvalds/linux/commit/06f9d950cb) (spi-mt65xx PM macros), [5f30668104](https://github.com/torvalds/linux/commit/5f30668104) (MediaTek pinctrl modules).
- Userspace: [alsa-ucm-conf#862](https://github.com/alsa-project/alsa-ucm-conf/pull/862).
- Local research (not in this repository): `~/Work/n1x-display/NV-KERNELS-DELTA.md`, `KERNEL-UPSTREAM-RESEARCH.md`, `N1X-ECOSYSTEM-RESEARCH.md`, `GB10-SLEEP-RESEARCH.md`, `NVIDIA-SPARK-UPDATES.md`, `SUSPEND.md`.
