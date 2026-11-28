# samsung-galaxy-book2-w737-firmware

Audio DSP, compute DSP, video and modem firmware for the Samsung Galaxy Book2 W737, from the driver bundle Samsung publishes for it on Windows Update.

The firmware only runs if Samsung signed it for this board, so linux-firmware cannot carry it until Samsung submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Windows Update hands out short-lived links only, so a `wu://` source names the update ID, revision and SHA-1 of a file, and [wudrivers](https://github.com/birkskyum/wudrivers) fetches a fresh link for it when the package builds. makepkg then checks the file against its SHA-256 like any other source.

## Source

- Qualcomm Subsystem driver 1.0.10750.0008 for the Galaxy Book2 W737 (Windows Update 200.0.4.0), `wu://1a2c5ce3-a607-4cb8-a591-f44bd0ee2d04/1/2e6995528154d0763c5467fd1d5d27781f0d6c69`, 93 MB, SHA-256 `1d0660a2fbcbb9907aa69d3199a98816ca3fc82ab44154a0259d32d0b8c8f162`, checked 2026-11-16.
- Qualcomm IPA driver 1.0.10600.1000 for the Galaxy Book2 W737 (Windows Update 200.0.4.0), `wu://1a2c5ce3-a607-4cb8-a591-f44bd0ee2d04/1/7b3d16931525815e8dffbb4ae3359a57dafd6ea6`, 1 MB, SHA-256 `544f0b2ff642846a2bf0754600be57ef8277c4ebd9dcf72b61cb3d1f463bfec8`, checked 2026-11-16.
- Qualcomm Adreno graphics driver 26.18.10620.0000 for the Galaxy Book2 W737 (Windows Update 200.0.4.0), `wu://1a2c5ce3-a607-4cb8-a591-f44bd0ee2d04/1/da7594df9670906b3016ffcb5c70283bbe66c197`, 29 MB, SHA-256 `949f9fa256d036d829a1429451514c4f6aa3fcb228078a36a0bc4c6d569be3f9`, checked 2026-11-16.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/sdm850/samsung/w737/ipa_fws.elf` | `c3ebf4d6191a09d661ad3ea7c0dde823f13765c93d9d22f5d6d56f1ef670a39a` | Qualcomm IPA driver 1.0.10600.1000 for the Galaxy Book2 W737 (Windows Update 200.0.4.0), `ipa_fws.elf` |
| `qcom/sdm850/samsung/w737/qcadsp850.mbn` | `852a27951da525bb5988551bdcb35558750f3ef3d251d217b3a8d336d58a8254` | Qualcomm Subsystem driver 1.0.10750.0008 for the Galaxy Book2 W737 (Windows Update 200.0.4.0), `qcadsp850.mbn` |
| `qcom/sdm850/samsung/w737/qccdsp850.mbn` | `11d49daaa8cc0fe5d699185ce38a656766d0e912cbc68faa8ebb605bb7d53dee` | Qualcomm Subsystem driver 1.0.10750.0008 for the Galaxy Book2 W737 (Windows Update 200.0.4.0), `qccdsp850.mbn` |
| `qcom/sdm850/samsung/w737/qcdsp1v2850.mbn` | `8b12520a1456112a8766e0b81c4879516ac8e1164b70184304ba103d6101e130` | Qualcomm Subsystem driver 1.0.10750.0008 for the Galaxy Book2 W737 (Windows Update 200.0.4.0), `qcdsp1v2850.mbn` |
| `qcom/sdm850/samsung/w737/qcdsp2850.mbn` | `1f8a0f38cf92c393dbe5d69f7811eb5adb5e2884efc4703ec624f1cdd6b589f1` | Qualcomm Subsystem driver 1.0.10750.0008 for the Galaxy Book2 W737 (Windows Update 200.0.4.0), `qcdsp2850.mbn` |
| `qcom/sdm850/samsung/w737/qcvss850.mbn` | `1e36a269697c9ce5115f1d78935b9433d2883ef05cd47181067f01fa9fe7964a` | Qualcomm Adreno graphics driver 26.18.10620.0000 for the Galaxy Book2 W737 (Windows Update 200.0.4.0), `qcvss850.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-sdm850-samsung-w737`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
