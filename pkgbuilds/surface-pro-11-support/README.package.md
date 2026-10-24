# surface-pro-11-support

Hardware support for the Microsoft Surface Pro 11 with Snapdragon X Elite and OLED display (`microsoft,denali-oled`) that no upstream package carries yet. Omarchy's Surface Pro 11 hardware setup (`install/hardware/microsoft/surface-pro-11.sh`) installs it with the `linux-sp11` kernel.

The package contains no Microsoft or Qualcomm DSP firmware; `qcom-firmware-extract` copies that from the machine's own Windows installation.

## Contents

- **Wi-Fi board data** (`ath12k/WCN7850/hw2.0/board.bin`): the tablet's WCN7850 reports generic identifiers (subsystem `17cb:1107`, board-id 255) that match no record in linux-firmware's `board-2.bin`, so Wi-Fi fails to load board data. The build extracts one record, unmodified, from the installed `linux-firmware-atheros` and checks its size and SHA-256. That record (`subsystem-device=3378`) is Qualcomm's own reference-design board, not Surface calibration: it carries RF and regulatory tables for a different antenna design. It brings Wi-Fi up until the Surface Pro 11's own board data reaches linux-firmware.
- **Audio**
  - The AudioReach topology (`qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin`), built from `X1E80100-Microsoft-Surface-Pro-11.m4` against pinned `linux-msm/audioreach-topology` source and checked against the SHA-256 of the binary validated on the device.
  - ALSA UCM routing for speakers and microphones, derived from alsa-ucm-conf's Surface Pro 12in profile and linked from `conf.d/x1e80100/` by card name and by DMI identity. It sets a fixed hardware ceiling and leaves volume to software attenuation.
- **Cameras**: a WirePlumber rule that hides the monochrome infrared sensor from camera pickers, so apps see only the front and back cameras (provided by libcamera through `pipewire-libcamera`). It also gives libcamera's software ISP the measured black level of the front camera (IMX681). With the linear gain control in `linux-omarchy`'s IMX681 driver, that lets stock libcamera drive the front camera.
- **Battery**: after resume, a sleep hook writes the currently set charge thresholds back to the battery manager, which can lose them across suspend. It never chooses a limit: UPower or Omarchy's power settings do. With no limit set, it does nothing. The kernel driver restores the thresholds itself when the battery-manager service restarts.
- **Wi-Fi and Bluetooth addresses**: come from the `surface-snapdragon-addresses` dependency, which the Surface Laptop 8 shares.
- **Flex Keyboard**: attaching the keyboard pairs it over Bluetooth, the way Windows does, so it keeps working when detached. The tablet hands the keyboard its address and a fresh pairing key over the connector, and the keyboard pairs with LE legacy out-of-band pairing. This needs no user action and no Windows, and needs `linux-omarchy`'s KIP pairing node and LE legacy out-of-band pairing. A bond that still works is left alone. A bond that stopped working, because the keyboard was paired with another computer or with Windows since, is replaced on the next attach. Detaching the keyboard connects it over Bluetooth. Pairing also stores a 7.5-11.25 ms Bluetooth connection interval for the keyboard, which never asks for one; at Linux's default its touchpad moves in jerks. `sudo surface-pro-11-flex-pair` pairs by hand, and `--status` shows the keyboard's address and pairing state without changing anything.
- **Flex Keyboard touchpad**
  - After some resumes the attached keyboard's touchpad comes back in mouse mode, so two-finger scrolling, right click and palm rejection stop. After each resume a sleep hook starts a short job that reads the touchpad's mode and its surface and button switches and, if the touchpad is not in touchpad mode with both switches on, sets them the way the kernel does when the keyboard is attached. The job runs on its own, so it does not hold up the resume.
  - Detached, the touchpad works over Bluetooth, where libinput counts it as an external touchpad and turns palm rejection off. A libinput quirk marks it as the touchpad below a keyboard's keys, which turns palm rejection back on. Like libinput's entry for the attached touchpad, it also hides the right button the clickpad advertises.
- **Lid**: with the cover open, the lid line shows a false edge just after the SoC powers down in suspend, which wakes the machine at once. A sleep hook arms lid wake only when the machine suspends with the cover closed, so opening the cover still wakes it; the power button wakes it either way.
- **Pen and touch**: the touch controller resets its firmware on resume, and a running iptsd never recovers. A sleep hook stops iptsd before suspend and starts it again after.

Every service and sleep hook checks for the `microsoft,denali-oled` device tree and does nothing elsewhere.

## Retirement

- Board data: drop once linux-firmware carries a Surface Pro 11 entry, selected by a `qcom,calibration-variant` in the Denali device tree.
- Topology and UCM: drop once audioreach-topology and alsa-ucm-conf ship Surface Pro 11 profiles. alsa-ucm-conf shipping `MICROSOFT-Surface-Pro-11.conf` would conflict with this package's file, so drop the UCM here first.
- Touchpad hook: drop once the kernel keeps the attached touchpad in touchpad mode across resume.
- Touchpad quirk: drop once libinput carries an entry for the Flex Keyboard over Bluetooth.

## Licences

- Packaging, scripts and units: MIT.
- Topology source and UCM files: BSD-3-Clause, from audioreach-topology and alsa-ucm-conf.
- Board data: Qualcomm Atheros' linux-firmware licence.

All licence texts are installed under `/usr/share/licenses/surface-pro-11-support/`.
