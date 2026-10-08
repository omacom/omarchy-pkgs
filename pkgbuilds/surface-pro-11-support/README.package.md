# surface-pro-11-support

Hardware support for the Microsoft Surface Pro 11 with Snapdragon X Elite and OLED display (`microsoft,denali-oled`) that no upstream package carries yet. Omarchy's Surface Pro 11 hardware setup (`install/hardware/microsoft/surface-pro-11.sh`) installs it with the `linux-sp11` kernel.

The package contains no Microsoft or Qualcomm DSP firmware; `qcom-firmware-extract` copies that from the machine's own Windows installation.

## Contents

- **Wi-Fi board data** (`ath12k/WCN7850/hw2.0/board.bin`): the tablet's WCN7850 reports generic identifiers (subsystem `17cb:1107`, board-id 255) that match no record in linux-firmware's `board-2.bin`, so Wi-Fi fails to load board data. The build extracts one record, unmodified, from the installed `linux-firmware-atheros` and checks its size and SHA-256. That record (`subsystem-device=3378`) is Qualcomm's own reference-design board, not Surface calibration: it carries RF and regulatory tables for a different antenna design. It brings Wi-Fi up until the Surface Pro 11's own board data reaches linux-firmware.
- **Audio**
  - The AudioReach topology (`qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin`), built from `X1E80100-Microsoft-Surface-Pro-11.m4` against pinned `linux-msm/audioreach-topology` source and checked against the SHA-256 of the binary validated on the device.
  - ALSA UCM routing for speakers and microphones, derived from alsa-ucm-conf's Surface Pro 12in profile and linked from `conf.d/x1e80100/` by card name and by DMI identity. It sets a fixed hardware ceiling and leaves volume to software attenuation.
- **Cameras**: a WirePlumber rule that hides the monochrome infrared sensor from camera pickers, so apps see only the front and back cameras (provided by libcamera through `pipewire-libcamera`).
- **Battery**: after resume, a sleep hook writes the currently set charge thresholds back to the battery manager, which can lose them across suspend. It never chooses a limit: UPower or Omarchy's power settings do. With no limit set, it does nothing. The kernel driver restores the thresholds itself when the battery-manager service restarts.
- **Bluetooth**: the WCN7850 stays an unconfigured controller until given a public address. A udev rule starts `surface-pro-11-bluetooth-address@<hci>.service` for each Qualcomm UART controller. The service sets the firmware's Wi-Fi address (`MacAddressEmulationAddress`) minus one, which is the identity Windows uses and the Flex Keyboard bonds to. Override it with `SP11_BLUETOOTH_PUBLIC_ADDRESS` in `/etc/surface-pro-11-bluetooth-address.conf`.
- **Wi-Fi address**: ath12k reports a Qualcomm placeholder (`00:03:7f:…`) as the WCN7850's permanent address, a different one on each boot. A udev rule runs `surface-pro-11-wifi-address` as each ath12k Wi-Fi interface is added, before NetworkManager takes it, and sets the firmware's Wi-Fi address (`MacAddressEmulationAddress`, the address Windows uses). It does nothing on other machines and leaves an interface that is already up alone. The permanent address the kernel reports stays the placeholder, and NetworkManager's per-network cloned addresses still apply on top. Override it with `SP11_WIFI_ADDRESS` in `/etc/surface-pro-11-wifi-address.conf`.
- **CPU power**: `surface-pro-11-power-profile-cpufreq.service` caps the CPU clusters per power profile (1.92 GHz power-saver, 2.52 GHz balanced, full range for performance), because the firmware profile alone does not limit short loads. It follows power-profiles-daemon, which needs `power-profiles-daemon-surface-pro-11` to see the Surface's platform profile.
- **Pen and touch**: the touch controller resets its firmware on resume, and a running iptsd never recovers. A sleep hook stops iptsd before suspend and starts it again after.

Every service and sleep hook checks for the `microsoft,denali-oled` device tree and does nothing elsewhere.

## Retirement

- Board data: drop once linux-firmware carries a Surface Pro 11 entry, selected by a `qcom,calibration-variant` in the Denali device tree.
- Topology and UCM: drop once audioreach-topology and alsa-ucm-conf ship Surface Pro 11 profiles. alsa-ucm-conf shipping `MICROSOFT-Surface-Pro-11.conf` would conflict with this package's file, so drop the UCM here first.
- Bluetooth: drop once the Denali device tree provides `local-bd-address` or the firmware supplies a public address.
- Wi-Fi address: drop once ath12k takes the address from the device tree (`local-mac-address`) and the Denali device tree gets one.

## Licences

- Packaging, scripts and units: MIT.
- Topology source and UCM files: BSD-3-Clause, from audioreach-topology and alsa-ucm-conf.
- Board data: Qualcomm Atheros' linux-firmware licence.

All licence texts are installed under `/usr/share/licenses/surface-pro-11-support/`.
