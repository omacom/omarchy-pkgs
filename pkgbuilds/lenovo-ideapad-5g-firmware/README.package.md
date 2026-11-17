# lenovo-ideapad-5g-firmware

Audio DSP, compute DSP, GPU and modem firmware for the Lenovo IdeaPad 5G 14Q8X05, from the driver bundle Lenovo publishes for it on Windows Update.

The firmware only runs if Lenovo signed it for this board, so linux-firmware cannot carry it until Lenovo submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Windows Update hands out short-lived links only, so a `wu://` source names the update ID, revision and SHA-1 of a file, and [wudrivers](https://github.com/birkskyum/wudrivers) fetches a fresh link for it when the package builds. makepkg then checks the file against its SHA-256 like any other source.

## Source

- Qualcomm WLAN driver 1.0.1600.0000 for the 82KF IdeaPad 5G 14Q8X05 (Windows Update 200.0.3.0), `wu://58e60859-8f55-4ef0-b8b9-5bf35d6b20be/1/a6156fd58f815a8f470f8c5db0ac7c298db64dbd`, 2 MB, SHA-256 `4641519a02db3db7c837f269e5cb195c76f8b5f194cc97c4583c6682d0823ad2`, checked 2026-11-16.
- Qualcomm Compute DSP Subsystem extension 1.0.1600.0000 for the 82KF IdeaPad 5G 14Q8X05 (Windows Update 200.0.3.0), `wu://58e60859-8f55-4ef0-b8b9-5bf35d6b20be/1/c3e05090fc46fdbea241c3c0a1c74ceba286a060`, 3 MB, SHA-256 `b2d5c7861a52c22edfe26be20c446d38f7c3a623f987cf5b802cf582dadf8b28`, checked 2026-11-16.
- Qualcomm Audio DSP Subsystem extension 1.0.1600.0001 for the 82KF IdeaPad 5G 14Q8X05 (Windows Update 200.0.3.0), `wu://58e60859-8f55-4ef0-b8b9-5bf35d6b20be/1/785b6fe34d22f74f71c950e2f7382e303479ca86`, 15 MB, SHA-256 `815d18b38d1d279b51cc4e1efd565a343ae5516359c0c31e6543ac44e4ba1445`, checked 2026-11-16.
- Qualcomm Adreno graphics driver 27.20.1640.0000 for the 82KF IdeaPad 5G 14Q8X05 (Windows Update 200.0.3.0), `wu://58e60859-8f55-4ef0-b8b9-5bf35d6b20be/1/ed1719eaaf12377682796d86dc47b61d46ec5b09`, 34 MB, SHA-256 `1fa296f8247b2cf0768079d2d1a0bf3a3c4b715d040273303b9614cb636f07ef`, checked 2026-11-16.
- Qualcomm Modem Subsystem extension 1.0.1600.0002 for the 82KF IdeaPad 5G 14Q8X05 (Windows Update 200.0.3.0), `wu://58e60859-8f55-4ef0-b8b9-5bf35d6b20be/1/376227d8a3e1f92d6c1e8e17521924e79697dda2`, 36 MB, SHA-256 `bdff9d3603e111d6d442edb3f3e0cc6519b17c8391da6f5e0fa334e16c0d19eb`, checked 2026-11-16.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/sc8180xp/LENOVO/82KF/qcadsp8180.mbn` | `af96686581d869fb0b038c5650745c95a1582dfa7895323acf31929b03fd9d00` | Qualcomm Audio DSP Subsystem extension 1.0.1600.0001 for the 82KF IdeaPad 5G 14Q8X05 (Windows Update 200.0.3.0), `qcadsp8180.mbn` |
| `qcom/sc8180xp/LENOVO/82KF/qccdsp8180.mbn` | `66816c7815cbb90fd2136de63fe76392a37fc96a18c9d0bf51e3261f5f7dcfda` | Qualcomm Compute DSP Subsystem extension 1.0.1600.0000 for the 82KF IdeaPad 5G 14Q8X05 (Windows Update 200.0.3.0), `qccdsp8180.mbn` |
| `qcom/sc8180xp/LENOVO/82KF/qcdxkmsuc8180.mbn` | `7bc9035fc38bcdc49e0a2ffbb797e65cf331592e4fab3984ae2fdacf271a4bbb` | Qualcomm Adreno graphics driver 27.20.1640.0000 for the 82KF IdeaPad 5G 14Q8X05 (Windows Update 200.0.3.0), `qcdxkmsuc8180.mbn` |
| `qcom/sc8180xp/LENOVO/82KF/qcmpss8180_nm.mbn` | `02a5958ce3de36c57c148f1ea426aef41d62f740a89275ff42c865f44fe155f5` | Qualcomm Modem Subsystem extension 1.0.1600.0002 for the 82KF IdeaPad 5G 14Q8X05 (Windows Update 200.0.3.0), `qcmpss8180_nm.mbn` |
| `qcom/sc8180xp/LENOVO/82KF/wlanmdsp.mbn` | `757ddc182369acd7dee153104c03011b973ced6da09461f84f41adc6e724d9b9` | Qualcomm WLAN driver 1.0.1600.0000 for the 82KF IdeaPad 5G 14Q8X05 (Windows Update 200.0.3.0), `WLANMDSP.MBN` |

## How Omarchy installs it

The package provides `qcom-firmware-sc8180xp-lenovo-82kf`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
