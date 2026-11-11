# linux-omarchy-dtbs

The Snapdragon laptops get no device tree from their firmware. Their UKI carries one for each laptop (`DeviceTreeAuto=`), and systemd-stub picks it by the laptop's hardware IDs. This package installs those trees under `/boot/dtbs/linux-omarchy/qcom`, and under `/usr/lib/systemd/boot/hwids/aa64/linux-omarchy` the hardware IDs systemd's own list doesn't have yet. `linux-omarchy` shipped both itself until `7.3-46` and now depends on this package, so the two always come together. This package in turn depends on the kernel whose headers it was built from, or a newer one, so new trees never install next to an older kernel.

## How it builds

`linux-omarchy-headers` ships the sources of every tree the kernel build makes, the files they include, the dt-bindings headers and the kernel's own `dtc` ([`linux-omarchy-aarch64`](../linux-omarchy-aarch64/README.md#snapdragon-laptops)). `prepare()` copies those sources and applies this recipe's `*.patch` files to the copy. `build()` compiles every `qcom/*.dts` in it with the headers' `dtc`, the way Kbuild does. There is no kernel build, so a new laptop's tree ships in a minute.

Every tree gets the symbols an overlay needs (`-@`). Kbuild adds them only to the trees that have an EL2 variant, 50 of 72, and those 50 are the same bytes as the kernel package's at `7.3-42`. The other 22 differ only by the symbols, which add about 1 MB to the 14 MB of trees, and an overlay can then go on any of them.

`.omarchy/package.json` rebuilds this package (`rebuild_on`) once a new `linux-omarchy-aarch64` is on edge, so the trees follow the kernel's tree patches within a sync. The package's description names the kernel the trees were built from (`pacman -Qi linux-omarchy-dtbs`), which shows trees that trail their kernel.

## Adding a laptop

- A tree, or a fix to one the kernel ships: a patch in kernel format (`git format-patch` against the kernel's tree), added to `source` and `b2sums`. It can only touch files under `arch/arm64/boot/dts/` or `include/dt-bindings/`, so a posted patch loses its `Makefile` and binding hunks first. Every `qcom/*.dts` is built, so a new tree needs no `Makefile` line. Patches apply in the order of `source`.
- Hardware IDs systemd doesn't list: the laptop's `.json` file, added to `source` and `b2sums`. The notes on the hardware ID files are in the kernel's README, with each laptop. A patch's notes are below.

A patch stays here until the kernel moves to a new version. Then `pkgver` follows it, `pkgrel` starts again at 1, and the patches the new kernel has are dropped. If the kernel's recipe takes a patch from here before that, `prepare()` finds it in the kernel's sources, skips it and raises a warning on the CI run, and the patch can go. A patch that neither applies nor is in the sources stops the build.

## Patches

`0001` adds the Surface Laptop 7 15" (`x1e80100-microsoft-romulus15`) touchpad, a HID-over-SPI device on `spi19`, using the Surface Pro 11's spi-hid and QSPI patches in the kernel. On its own the pad stays in a mouse mode: pointer, tap and press to click. iptsd adds two-finger scroll, pinch and two-finger tap, but press to click stops registering, because iptsd doesn't decode the pad's haptic report yet. The 13.8" isn't covered, and hasn't been tested. By Jason Bruce Jones.

`0002` adds the Lenovo IdeaCentre Mini 01Q8X10 with the Snapdragon X X1-26-100 (`purwa-lenovo-ideacentre-mini-01q8x10`), on the board file the kernel's `2821` splits out of the X1P-64 model's tree. systemd's own hardware IDs already pick it. The compatible follows the binding in `2820`, so it ends in `qcom,x1p42100` where Jens Glathe's latest tree has `lenovo,thinkpad-t14s`, `qcom,x1e80100`. It loads its firmware from `qcom/x1p42100/LENOVO/91B6`, which `lenovo-ideacentre-mini-x-firmware` installs. By Jens Glathe.

`0003` and `0004` fix the LCD Surface Pro 11's tree (`x1p64100-microsoft-denali`, Snapdragon X Plus X1P-64-100). Its LG LP129WT3 panel takes its brightness from a PWM signal and ignores eDP AUX brightness, so `0003` drives a `pwm-backlight` from PMK8550 PWM channel 0 out of GPIO5, as on the Surface Laptop 7. The part has 10 cores, and `0004` deletes the fused-off CPU7 and CPU11, which PSCI refuses to start. Both work on the kernel's existing drivers. The kernel's `2157` gives the remaining cores in those clusters cpufreq, and `2160` adds the panel's timings. By Iván Ruiz.

`0005` gives the HP OmniBook X 14 (`x1-hp-omnibook-x14.dtsi`, both variants) its internal microphones. The two mics are on VA DMIC0 and DMIC1 and are powered by the WCD938x's MIC BIAS1, but the tree routes them to MIC BIAS3, as the CRD's does, so capture powers the wrong bias and the mics record silence. The patch routes DMIC0 and DMIC1 to MIC BIAS1 and VA MIC BIAS1, as the ThinkPad T14s's and the Zenbook A14's trees do. Found and tested by TheArtForm on an OmniBook X 14-fe0, where speech records on both channels through the laptop's UCM profile with no workaround (basecamp/omarchy#17396). LukeMech found the same bias on this model. The X1P-42-100 variant shares the file and hasn't been tested.
