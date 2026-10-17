# m1n1-aurora

m1n1 v1.6.1 from aurora-silicon/m1n1 (06a4601a351ebfd1abb6abba9a44c34e40d94776) with RC, NHI and PCIe adapter alias fallbacks for the USB4 tunables, plus the Omarchy boot logos. Aurora's device trees name those aliases `usb4-N-acio`, `usb4-N-nhi` and `usb4-N-pcie-adapter`; stock m1n1 only looks up the `usb4_N_*` names. Latest Aurora m1n1 main is not qualified.

## Pairing with linux-aurora

- It provides `m1n1=1.6.1.aurora1`, which satisfies linux-aurora's `m1n1>=1.6.1`, and conflicts with asahi-alarm's `m1n1`. pacman prefers a package literally named `m1n1` over a provider, so an Aurora transaction names `m1n1-aurora` explicitly and accepts its conflict with `m1n1` (`--ask 4` under `--noconfirm`).
- It owns `/usr/lib/asahi-boot/m1n1.bin`. asahi-scripts' `95-m1n1-install.hook` runs `update-m1n1` when that file, `/usr/lib/modules/*/dtbs/*` or U-Boot changes. `update-m1n1` writes m1n1, the device trees and gzipped U-Boot into `m1n1/boot.bin` on the system ESP. asahi-alarm's default takes the device trees from the newest `/lib/modules/*-ARCH/dtbs`, which is where linux-aurora installs its Apple DTBs. `/etc/default/update-m1n1` overrides are left alone.
- Raising linux-aurora's `_m1n1_version` above 1.6.1 needs an m1n1-aurora whose provided version satisfies it, released first.

## Qualification

Each bump is cold-boot qualified on the M1 Pro and M2 Max: package installation, the hook rebuilding `boot.bin`, the logo, physical boot and two external displays. A successful build is not hardware acceptance.
