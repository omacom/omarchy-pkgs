# surface-pro-11-support

Hardware support for the Microsoft Surface Pro 11 with Snapdragon X Elite and OLED display (`microsoft,denali-oled`) that no upstream package carries yet. Omarchy's Surface Pro 11 hardware setup (`install/hardware/microsoft/surface-pro-11.sh`) installs it with the `linux-sp11` kernel.

The package contains no Microsoft or Qualcomm DSP firmware; `qcom-firmware-extract` copies that from the machine's own Windows installation.

## Contents

- **Wi-Fi board data** (`ath12k/WCN7850/hw2.0/board.bin`): the tablet's WCN7850 reports generic identifiers (subsystem `17cb:1107`, board-id 255) that match no record in linux-firmware's `board-2.bin`, so Wi-Fi fails to load board data. The build extracts one record, unmodified, from the installed `linux-firmware-atheros` and checks its size and SHA-256. That record (`subsystem-device=3378`) is Qualcomm's own reference-design board, not Surface calibration: it carries RF and regulatory tables for a different antenna design. It brings Wi-Fi up until the Surface Pro 11's own board data reaches linux-firmware.
- **Audio**
  - The AudioReach topology (`qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin`), built from `X1E80100-Microsoft-Surface-Pro-11.m4` against pinned `linux-msm/audioreach-topology` source and checked against the SHA-256 of the binary validated on the device.
  - ALSA UCM routing for speakers and microphones, derived from alsa-ucm-conf's Surface Pro 12in profile and linked from `conf.d/x1e80100/` by card name and by DMI identity. It sets a fixed hardware ceiling and leaves volume to software attenuation.
- **Cameras**: a WirePlumber rule that hides the monochrome infrared sensor from camera pickers, so apps see only the front and back cameras (provided by libcamera through `pipewire-libcamera`).

## Retirement

- Board data: drop once linux-firmware carries a Surface Pro 11 entry, selected by a `qcom,calibration-variant` in the Denali device tree.
- Topology and UCM: drop once audioreach-topology and alsa-ucm-conf ship Surface Pro 11 profiles. alsa-ucm-conf shipping `MICROSOFT-Surface-Pro-11.conf` would conflict with this package's file, so drop the UCM here first.

## Licences

- Packaging, scripts and units: MIT.
- Topology source and UCM files: BSD-3-Clause, from audioreach-topology and alsa-ucm-conf.
- Board data: Qualcomm Atheros' linux-firmware licence.

All licence texts are installed under `/usr/share/licenses/surface-pro-11-support/`.
