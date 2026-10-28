# surface-pro-11-support

Hardware support for the Microsoft Surface Pro 11 with Snapdragon X Elite and OLED display (`microsoft,denali-oled`) that no upstream package carries yet. Omarchy's Surface Pro 11 hardware setup (`install/hardware/microsoft/surface-pro-11.sh`) installs it with the `linux-sp11` kernel.

The package contains no Microsoft or Qualcomm DSP firmware; `qcom-firmware-extract` copies that from the machine's own Windows installation.

## Contents

- **Wi-Fi board data** (`ath12k/WCN7850/hw2.0/board.bin`): the tablet's WCN7850 reports generic identifiers (subsystem `17cb:1107`, board-id 255) that match no record in linux-firmware's `board-2.bin`, so Wi-Fi fails to load board data. The build extracts one record, unmodified, from the installed `linux-firmware-atheros` and checks its size and SHA-256. That record (`subsystem-device=3378`) is Qualcomm's own reference-design board, not Surface calibration: it carries RF and regulatory tables for a different antenna design. It brings Wi-Fi up until the Surface Pro 11's own board data reaches linux-firmware.
- **Audio**
  - The AudioReach topology (`qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin`), built from `X1E80100-Microsoft-Surface-Pro-11.m4` against pinned `linux-msm/audioreach-topology` source and checked against the SHA-256 of the binary validated on the device.
  - ALSA UCM routing for speakers and microphones, derived from alsa-ucm-conf's Surface Pro 12in profile and linked from `conf.d/x1e80100/` by card name and by DMI identity. It sets a fixed hardware ceiling and leaves volume to software attenuation.
  - **Speaker tuning and protection** (`pipewire.conf.d/50-surface-pro-11-speakers.conf`): a PipeWire filter chain, "Internal speakers", that becomes the default sink in front of the hardware sink. Windows drives these speakers through a Dolby effects chain whose per-device tuning does three things: a 20-band per-channel speaker correction EQ, a +6 dB volume maximizer, and a "regulator", a multiband limiter that holds the bass bands well below full scale while the rest may reach 0 dBFS. That regulator is the only speaker protection these amplifiers get on either system; the Qualcomm DSP's own is not available on Linux. The chain rebuilds it from the Windows values: the EQ as biquads fitted to the Dolby targets (left and right differ by about 1 dB), the gain, then a 96 dB/octave crossover into six bands, each with a brickwall limiter at the Windows ceiling (47 Hz -4.6 dB, 141 Hz -7 dB, 234 Hz -12 dB, 328 to 656 Hz -14.9 dB, 844 Hz -9.8 dB, above 933 Hz -0.5 dB), summed and capped at -0.5 dBFS. Measured on the device: transparent below the ceilings, EQ within 0.3 dB of the targets, ceilings held at band centres; a tone right at a band edge can exceed its ceiling by a few dB through the neighbouring band. Cost: about 3.5% of one core and about 15 ms of latency. The values come from this unit's Dolby tuning (`MSHW0486 REV_0D`); `/usr/lib/surface-pro-11-support/dolby2pipewire.py` regenerates the file from the XML on the Windows partition, and `--summary` prints the parsed tuning. The raw hardware sink and the chain's own output stream are hidden from sound settings, the way WirePlumber hides the hardware node under a split PCM (media classes `Audio/Sink/Internal` and `Stream/Output/Audio/Internal`), so "Internal speakers" is the only speaker output listed. The raw sink is still reachable by name for debugging: `pw-play --target alsa_output.platform-sound.HiFi__Speaker__sink` (`wireplumber.conf.d/51-surface-pro-11-speakers.conf`). Lowering the gain in the chain is always safe; raising a ceiling is not.
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
- Speaker chain: drop once the kernel or the DSP topology offers real speaker protection (V/I sense) on this hardware, or once a shared x1e80100 speaker-tuning package exists.
- Topology and UCM: drop once audioreach-topology and alsa-ucm-conf ship Surface Pro 11 profiles. alsa-ucm-conf shipping `MICROSOFT-Surface-Pro-11.conf` would conflict with this package's file, so drop the UCM here first.
- Touchpad hook: drop once the kernel keeps the attached touchpad in touchpad mode across resume.
- Touchpad quirk: drop once libinput carries an entry for the Flex Keyboard over Bluetooth.

## Licences

- Packaging, scripts and units: MIT.
- Topology source and UCM files: BSD-3-Clause, from audioreach-topology and alsa-ucm-conf.
- Board data: Qualcomm Atheros' linux-firmware licence.

All licence texts are installed under `/usr/share/licenses/surface-pro-11-support/`.
