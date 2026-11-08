# linux-omarchy-dtbs

The Snapdragon laptops get no device tree from their firmware. Their UKI carries one for each laptop (`DeviceTreeAuto=`), and systemd-stub picks it by the laptop's hardware IDs. This package installs those trees under `/boot/dtbs/linux-omarchy/qcom`, and under `/usr/lib/systemd/boot/hwids/aa64/linux-omarchy` the hardware IDs systemd's own list doesn't have yet. `linux-omarchy` shipped both itself until `7.3-40` and now depends on this package, so the two always come together.

## How it builds

`linux-omarchy-headers` ships the sources of every tree the kernel build makes, the files they include, the dt-bindings headers and the kernel's own `dtc` ([`linux-omarchy-aarch64`](../linux-omarchy-aarch64/README.md#snapdragon-laptops)). `prepare()` copies those sources and applies this recipe's `*.patch` files to the copy. `build()` compiles every `qcom/*.dts` in it with the headers' `dtc`, the way Kbuild does. There is no kernel build, so a new laptop's tree ships in a minute.

Every tree gets the symbols an overlay needs (`-@`). Kbuild adds them only to the trees that have an EL2 variant, 49 of 71. On the others the symbols add about 1 MB to the 14 MB of trees, and an overlay can then go on any of them. Built without `-@`, every tree is the same bytes as the kernel package's at `7.3-38`.

`.omarchy/package.json` rebuilds this package (`rebuild_on`) once a new `linux-omarchy-aarch64` is on edge, so the trees follow the kernel's tree patches within a sync.

## Adding a laptop

- A tree, or a fix to one the kernel ships: a patch in kernel format (`git format-patch` against the kernel's tree, paths under `arch/arm64/boot/dts/` or `include/dt-bindings/`), added to `source` and `b2sums`. Patches apply in the order of `source`.
- Hardware IDs systemd doesn't list: the laptop's `.json` file, added to `source` and `b2sums`. The notes on the files here are in the kernel's README, with each laptop.

Once the kernel takes a tree patch from here, the patch no longer applies and the build stops, and the patch goes. When the kernel moves to a new version, `pkgver` follows it and `pkgrel` starts again at 1.
