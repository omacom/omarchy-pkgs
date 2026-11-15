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

`0006` gives the Acer Aspire 16 AI (`x1p42100-acer-aspire-16-ai`) its sound card, wired as the ThinkBook 16's. It has two WSA8845 speaker amplifiers on the WSA bus, the WCD9385 headset codec, the two lid microphones on VA DMIC0 and DMIC1, and DisplayPort playback on both USB-C ports and HDMI. The microphones run at 2.4 MHz, because 4.8 MHz gives loud static. The card loads its topology from `acer-aspire-16-ai-audio`, and its UCM profile is in `alsa-ucm-conf`. Worked out and tested by GenericCPU on an A16-11M (omacom/omarchy#17555). The Aspire 14 AI shares the dtsi but not this card, since its speaker wiring isn't known.

`0007` lets the Surface Laptop 7's Wi-Fi (`x1e80100-microsoft-romulus.dtsi`, both sizes) ignore its rfkill pin. The WCN7850's hardware rfkill input reads as "radio off", so Wi-Fi comes up hard-blocked and never connects. The laptop has no Wi-Fi switch, and Windows ignores the pin through an ACPI setting a device tree boot doesn't see. ath12k skips the pin when the node has `disable-rfkill`, as the Surface Pro 11's and Surface Laptop 8's trees have it. Tested on the 15"; the 13.8" shares the node and hasn't been tested. By Jason Bruce Jones.

`0008` to `0011` give the Dell XPS 13 9345 (`x1e80100-dell-xps13-9345`) its sound card. `0008` adds its four WSA8845 amplifiers, two woofers and two tweeters on the WSA and WSA2 buses, and the speaker and microphone links, from Sibi Sankar's patch as Aleksandrs Vinarskis carries it. `0009` powers the two digital microphones from the LPASS microphone supply, by Aleksandrs Vinarskis. `0010` routes the right woofer from SPK1, which matches its SoundWire ports. `0011` switches the card to `dell,xps13-9345-sndcard`, so the kernel's `2451` plays four-channel streams to the right pair first, as the XPS 13 is wired. Without `2451` the card doesn't bind, so these need `linux-omarchy` 7.3-61. Its UCM profile is alsa-ucm-conf's own. Adapted and tested by 42lizard (Oliver Gassner), with all four channels on the right side after a clean boot (omacom/omarchy-pkgs#2293).

`0012` adds Qualcomm's Kalambo, the 6-core Snapdragon X2 Plus X2P-42-100 (`kalambo.dtsi`), as accepted into the qcom tree for 7.5. It is Mahua without CPU cluster 0, with its own PDC ranges and SCMI mailbox, and needs no driver change. It labels `cpus` and `cpu-map` in `glymur.dtsi`, which only adds those two symbols to the Glymur and Mahua trees. By Gopikrishna Garmidi.

`0013` to `0019` add 15 laptops and desktops, written from the DSDT in each maker's BIOS update on the sibling tree whose power tables match. Each patch says what it describes and from where.

- `0013` HP EliteBook 6 G2q (`mahua-hp-elitebook-6-g2q`), on the OmniBook X 16's tree.
- `0014` ASUS Vivobook S16 S3607NA (`glymur-asus-vivobook-s16-s3607na`), on the Zenbook A14 UX3407NA's.
- `0015` ASUS Vivobook S14 S5408QA, S14 Flip TP5408QA, S16 S5608QA and S16 Flip TP5608QA (`x126100-asus-vivobook-s*`), one board file on the Zenbook 14 UX3480QA's tree.
- `0016` Lenovo IdeaPad Vibe 14Q8X12 and 15Q8X12 (`x126100-lenovo-ideapad-vibe-*`), on the IdeaPad Slim 3x's.
- `0017` Dynabook XD5 (`x1p42100-dynabook-xd5`), on the HP EliteBook 6 G1q's.
- `0018` ASUS V400 AiO VM441QA and VM471QA (`x126100-asus-v400-aio-*`).
- `0019` Lenovo IdeaPad Slim 5x 13Q8Y11 and 15Q8Y11, IdeaPad 5x 2-in-1 14Q8Y11 and ThinkBook 14 Gen 9 (`kalambo-lenovo-*`), on `0012`, with the Yoga Slim 7x Gen 11's rails.

`0020` adds the 13-inch Surface Pro, 12th Edition (`mahua-microsoft-surface-pro-12th-edition`), on the Surface Laptop 8 13.8"'s tree, whose power tables it shares, and `0021` the Surface Laptop 13in 2nd Edition and Surface Pro 12in 2nd Edition (`kalambo-microsoft-*`), on `0012`, with a shared board file. Each is written from the DSDT in Microsoft's firmware update. Their time, battery and charger come from SAM, as on the Surface Laptop 8, so the trees turn the PMIC clock off and need `linux-omarchy` 7.3-62, whose `2776` to `2778` give them their SAM devices. `mahua-microsoft-surface-pro-12th-edition.json` and the two `kalambo-microsoft-*.json` carry the manufacturer and product, and manufacturer and SKU CHIDs of each model's consumer and business SKUs, from Microsoft's SKU reference, which gives the strings as the firmware reports them.

Most firmware folders they name aren't installed by any package yet, so those machines start without their DSPs.

`x1e80100-microsoft-denali-5g.json` gives the Surface Pro 11 with 5G the OLED tree. It reads `Microsoft Surface Pro with 5G, 11th Edition`, which systemd's entry doesn't list, so it got no tree. The entry carries CHIDs 3 to 10 from an owner's SMBIOS (DanaGoyette in ubuntu/stubble#34) and the manufacturer and SKU CHID of its other three SKUs. The 5G comes with both panels, and systemd-stub compares the panel CHIDs in `x1p64100-microsoft-denali.json` first, so an LCD unit keeps the LCD tree. Neither tree has a PCIe port for the modem.

`0022` moves the Surface Pro 12th Edition's audio and compute DSP firmware to `qcom/glymur/microsoft/surface-pro-12th-edition`, where its tree already loads the SoCCP and USB4 router images. It loaded them from the Surface Laptop 8's folder, but Microsoft's package for the tablet has an audio DSP image of its own.

Hardware IDs for eight of the machines `0013` to `0019` added, so systemd-stub picks their trees. They are the manufacturer and product CHID, and with the board where it is known, from units that ran Geekbench. The HP split reproduces the IDs an OmniBook 5 14-he0 reports in ubuntu/stubble#75, and the Lenovo one the Yoga Slim 7x Gen 11's in stubble.

- `mahua-hp-elitebook-6-g2q.json`: `HP`, `HP EliteBook 6 G2q 14 inch Notebook Next Gen AI PC`, board `8F2B`, the same on X2E-84-100 and X2P-64-100 units.
- `kalambo-lenovo-ideapad-slim5x-13q8y11.json`, `-15q8y11.json` and `kalambo-lenovo-ideapad-5x-2in1-14q8y11.json`: `LENOVO` with the machine types `83RK`, `83RL` and `83UK` and board `LNVNB161216`. One 83UK reported them from Ubuntu.
- `kalambo-lenovo-thinkbook-14-gen9.json`, `x126100-lenovo-ideapad-vibe-14q8x12.json` and `-15q8x12.json`: `LENOVO` with the machine types `22BB`, `84A9` and `84AA`, which Lenovo reports as the product name on its laptops. No unit of these has reported yet.
- `x1p42100-dynabook-xd5.json`: `Dynabook Inc.`, `dynabook XD5`, board `DBIFXN00`. The direct-sale `dynabook XD/ZA` on the same board, sometimes with the X1E-78-100, reports another product name and doesn't match.

`0023` adds the 2025 HP OmniBook X 14 (14-kr0) and X 16 (16-cp0) with the Snapdragon X Plus X1P-42-100, on board 8F45 (`x1p42100-hp-omnibook-x14-kr0`, `x1p42100-hp-omnibook-x16-cp0`). The ACPI tables in the BIOS capsule of HP's driver pack sp172628 match the OmniBook 5 14-he0's board (8E33) in every device resource, power vote and wake pin, so the board file builds on that tree and only names its own firmware folder, `qcom/x1p42100/hp/omnibook-x16-cp0`, which `hp-omnibook-x16-cp0-firmware` fills. The two sizes differ in the tables only by values the firmware fills in at boot.

`0024` adds the 2026 HP OmniBook 5 14 (14-he1) with the 6-core X2P-42-100 on `0012`'s Kalambo (`kalambo-hp-omnibook-5-14-he1xxx`). HP builds it on the OmniBook 5 16-bf1's mainboard, 8F47, whose BIOS in sp173974 both run, so its board file carries the 16-bf1's nodes over unchanged and loads the 16-bf1's firmware folder. The 16-bf1's board file can't be included on `kalambo.dtsi`, since both pull in `mahua.dtsi`.

`x1p42100-hp-omnibook-x14-kr0.json`, `x1p42100-hp-omnibook-x16-cp0.json` and `kalambo-hp-omnibook-5-14-he1xxx.json` carry the manufacturer and product, and manufacturer, product and board CHIDs, from units that ran Geekbench: `HP OmniBook X Laptop 14-kr0xxx` and `16-cp0xxx` on board `8F45`, and `HP OmniBook 5 Laptop 14-he1xxx` on `8F47`.

`0025` adds the Acer Swift Spin 14 AI (SFSP14-Q51T) with the Snapdragon X2 Elite X2E-78-100, a Mahua (`mahua-acer-swift-sfsp14-q51t`). It is written from the ACPI tables in Acer's BIOS 1.06, whose power tables match the HP EliteBook 6 G2q's, so it starts from that tree: keyboard at 0x3c on i2c0, an ELAN or PixArt touchpad on i2c4, the Wacom touchscreen and pen on i2c8, its two USB-C ports on `usb_0` and `usb_2`, the USB-A port on the multiport controller and the cameras on `usb_hs`. The GPU stays off, as on the other Mahua trees. It loads its DSP firmware from `qcom/glymur/ACER/SFSP14-Q51T`, which `acer-swift-spin-14-ai-firmware` fills.

`mahua-acer-swift-sfsp14-q51t.json` carries the manufacturer and product CHID, `Acer` and `Swift SFSP14-Q51T`, which Geekbench units report and the BIOS image's SMBIOS defaults confirm.

`0026` turns on the Acer Aspire 16 AI's video encoder and decoder (Iris), so it gets hardware H.264 and HEVC through V4L2. Its firmware, `qcvss8380_pa.mbn`, isn't in Acer's driver download, but an owner's Windows copy is byte for byte the one in Dell's Adreno X1-85/X1-45 graphics driver 2CHK7, and `acer-aspire-16-ai-firmware` installs it into the laptop's own folder from there. Asked for by Phandoxx (birkskyum/arewearmyet#5).

