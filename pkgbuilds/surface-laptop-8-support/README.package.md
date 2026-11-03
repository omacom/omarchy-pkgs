# surface-laptop-8-support

Hardware support for the 13.8-inch Microsoft Surface Laptop 8 with Snapdragon X2 Elite (`microsoft,surface-laptop8`) that no upstream package carries yet. `linux-omarchy` carries the laptop's kernel patches and device tree from 7.3-4.

The package contains no Microsoft or Qualcomm DSP firmware; `qcom-firmware-extract` copies that from the machine's own Windows installation.

## Contents

- **Wi-Fi board data** (`ath12k/WCN7850/hw2.0/board.bin`): the laptop's WCN7850 reports generic identifiers (subsystem `17cb:1107`, board-id 255) that match no record in linux-firmware's `board-2.bin`, so Wi-Fi fails to load board data. The build extracts one record, unmodified, from the installed `linux-firmware-atheros` and checks its size and SHA-256. It is the record `surface-pro-11-support` uses: Qualcomm's own reference-design board (`subsystem-device=3378`), not Surface calibration, with RF and regulatory tables for a different antenna design. Windows uses board data of its own that linux-firmware does not carry. With this record and linux-firmware's Wi-Fi firmware, the laptop connects on 6 GHz at 320 MHz.
- **Audio**
  - The AudioReach topology (`qcom/glymur/GLYMUR-Microsoft-Surface-Laptop-8-tplg.bin`), built from `GLYMUR-Microsoft-Surface-Laptop-8.m4` against pinned `linux-msm/audioreach-topology` source and checked against the SHA-256 of the binary validated on the laptop. It is the Glymur reference design's topology with two playback channels on the laptop's single WSA bus.
  - ALSA UCM routing for the two speakers and the microphones, derived from alsa-ucm-conf's Glymur reference profile and linked from `conf.d/glymur/` by the card's DMI name. It sets a fixed hardware ceiling and leaves volume to software attenuation.
- **Device tree selection**: a hardware-ID file that lets systemd-stub pick the laptop's device tree from the UKI by its SMBIOS identity.
- **Firmware the boot firmware starts**: a `qcom-firmware-extract` board list naming the SOCCP pair (battery, charging and USB-C), which the laptop's boot firmware starts before Linux and no Windows driver package carries, so once this package is installed the extractor neither searches for it nor reports it missing. The installer runs the extractor before it installs this package, so that first run still lists them.
- **USB4 router firmware**: the USB4 host router's firmware exists only inside Qualcomm's Windows USB4 driver (`QcUsb4Filter8480.sys`), so neither linux-firmware nor `qcom-firmware-extract` has it. `surface-laptop8-usb4-firmware` finds the driver in the Windows driver store, read-only, and copies out the one router image tested on this laptop, identified by its load-record layout and SHA-256; any other driver leaves USB4 off. The image is the same in Microsoft's, HP's and ASUS's packages. The router driver asks for it once while still in the initramfs, so the tool rebuilds the boot images, and the board list tells `qcom-firmware-extract` not to look for it.
- **Sleep**: s2idle, which reaches the SoC's low-power states, instead of the firmware's PSCI suspend, which returns at once; and a udev rule that lets idle USB controllers and PHYs runtime suspend, without which the SoC never collapses CX in s2idle.
- **Touchpad**: a libinput quirk for the ELAN 3370, which reports force rather than contact size, so light touches register.
- **Wi-Fi and Bluetooth addresses**: come from the `surface-snapdragon-addresses` dependency.

## Not covered

- **USB4 with BitLocker on**: the Windows partition cannot be read; turn BitLocker off in Windows and run `surface-laptop8-usb4-firmware` again.
- **USB4 after a full-disk install**: with Windows erased there is no driver to copy the router firmware from; `surface-laptop8-usb4-firmware FILE` takes a saved copy of `QcUsb4Filter8480.sys`.
- **Compute DSP (CDSP)**: `qcom-firmware-extract` 1-5 refuses the CDSP pair when Windows keeps more than one version of its driver package, as it does after a driver update.

## Retirement

- Board data: drop once linux-firmware carries a Surface Laptop 8 entry.
- Topology and UCM: drop once audioreach-topology and alsa-ucm-conf ship Surface Laptop 8 profiles.
- Hardware-ID file: drop once systemd ships one for this model.
- Touchpad quirk: drop once libinput ships it.
- USB4 router firmware tool: drop once Qualcomm publishes the router firmware in linux-firmware.

## Licences

- Packaging and configuration: MIT. `extract-ath12k-board.py` is Brandon Williams' (MIT), from `surface-pro-11-support`.
- Topology source and UCM files: BSD-3-Clause, from audioreach-topology and alsa-ucm-conf.
- Board data: Qualcomm Atheros' linux-firmware licence.

All licence texts are installed under `/usr/share/licenses/surface-laptop-8-support/`.
