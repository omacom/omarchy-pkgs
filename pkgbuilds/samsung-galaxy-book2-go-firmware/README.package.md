# samsung-galaxy-book2-go-firmware

Audio DSP, compute DSP, GPU, video and modem firmware for the Samsung Galaxy Book2 Go, from the driver bundle Samsung publishes for it on Windows Update.

The firmware only runs if Samsung signed it for this board, so linux-firmware cannot carry it until Samsung submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Windows Update hands out short-lived links only, so a `wu://` source names the update ID, revision and SHA-1 of a file, and [wudrivers](https://github.com/birkskyum/wudrivers) fetches a fresh link for it when the package builds. makepkg then checks the file against its SHA-256 like any other source.

## Source

- Qualcomm Adreno graphics driver 30.0.4056.4400 for the Galaxy Book2 Go (Windows Update 200.0.12.0), `wu://35adcb86-2ccf-4480-b34d-527ecd301360/1/ca85263a87066de9a457a3daba27bf48eb7ee09c`, 87 MB, SHA-256 `772aaf735947e6db60db98d2608aa91f94906f8fad8179c8f443d61fa095bc7f`, checked 2026-11-16.
- Qualcomm IPA driver 1.0.4056.4400 for the Galaxy Book2 Go (Windows Update 200.0.12.0), `wu://35adcb86-2ccf-4480-b34d-527ecd301360/1/7670884534fa251bc27d1279bf3108d72ded4716`, 1 MB, SHA-256 `7da90b8c1b2dfbf51dba90a25d6b44363ab2afdc9e87f139912a32e72be0add7`, checked 2026-11-16.
- Qualcomm WLAN driver 1.0.3710.9700 for the Galaxy Book2 Go (Windows Update 200.0.12.0), `wu://35adcb86-2ccf-4480-b34d-527ecd301360/1/33cfe55574a1a4717db4d924eff599c9ca0cd25a`, 4 MB, SHA-256 `641870bdccb47a03a42c50755e517bf40515ecceb48f05c8d4f1bb69acd3d8f3`, checked 2026-11-16.
- Qualcomm Audio DSP Subsystem extension 2.0.4000.0004 for the Galaxy Book2 Go (Windows Update 200.0.12.0), `wu://35adcb86-2ccf-4480-b34d-527ecd301360/1/f4272c8de0ad840085703e657cdd03cfb8de7d56`, 7 MB, SHA-256 `2f27e9048da265c6a08b5c76b0885838d2d7fd108f7a14537d073140983fd8f4`, checked 2026-11-16.
- Qualcomm Compute DSP Subsystem extension 2.0.4056.4400 for the Galaxy Book2 Go (Windows Update 200.0.12.0), `wu://35adcb86-2ccf-4480-b34d-527ecd301360/1/7a0da6d23160b03b69d6c344c874ea69a860a5b2`, 12 MB, SHA-256 `2fbc1fa851c83a37e4bdd0a0ae2cb70baa1d1fbd62da1f882b7e568f82ed4cb2`, checked 2026-11-16.
- Qualcomm Modem Subsystem extension 1.0.0.0025 for the Galaxy Book2 Go (Windows Update 200.0.12.0), `wu://35adcb86-2ccf-4480-b34d-527ecd301360/1/c3bc702a2daf163e3eae2a91bacec2a5b659814f`, 58 MB, SHA-256 `347c1f5c4e410bbd7b50ff56476017eda9470c768adb16a9f40e4e26c1194145`, checked 2026-11-16.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/sc7280/Samsung/galaxy-book2-go/ipa_fws.elf` | `42707d11ab474fe7f9e24bb0ca3a1013a0971b96322ae2f80465c01cb302836e` | Qualcomm IPA driver 1.0.4056.4400 for the Galaxy Book2 Go (Windows Update 200.0.12.0), `ipa_fws.elf` |
| `qcom/sc7280/Samsung/galaxy-book2-go/qcadsp7280.mbn` | `4de02d2963101ba4825c58fa29d4452b27300ed65b36bdced8c4a9e9098d370b` | Qualcomm Audio DSP Subsystem extension 2.0.4000.0004 for the Galaxy Book2 Go (Windows Update 200.0.12.0), `qcadsp7280.mbn` |
| `qcom/sc7280/Samsung/galaxy-book2-go/qccdsp7280.mbn` | `278111b1548eab9a78bb0c8c783dedcff5112d213f4e1516d1ae433be25bb8ee` | Qualcomm Compute DSP Subsystem extension 2.0.4056.4400 for the Galaxy Book2 Go (Windows Update 200.0.12.0), `qccdsp7280.mbn` |
| `qcom/sc7280/Samsung/galaxy-book2-go/qcdxkmsuc7280.mbn` | `585700de2252d03019fb933974bee04983c3ade49b4ee105ee199ed9f9ef5190` | Qualcomm Adreno graphics driver 30.0.4056.4400 for the Galaxy Book2 Go (Windows Update 200.0.12.0), `qcdxkmsuc7280.mbn` |
| `qcom/sc7280/Samsung/galaxy-book2-go/qcmpss7280.mbn` | `3e182c1e3ffbf77091d8287d983c3246e8eb608850889724daa03f953f091d6d` | Qualcomm Modem Subsystem extension 1.0.0.0025 for the Galaxy Book2 Go (Windows Update 200.0.12.0), `qcmpss7280.mbn` |
| `qcom/sc7280/Samsung/galaxy-book2-go/qcvss7280.mbn` | `5c4cfabe7afd459a2577ad724e1c45b5dedcc767169f455a10fc8f7218af0f09` | Qualcomm Adreno graphics driver 30.0.4056.4400 for the Galaxy Book2 Go (Windows Update 200.0.12.0), `qcvss7280.mbn` |
| `qcom/sc7280/Samsung/galaxy-book2-go/wpss.mbn` | `6ae6ca9c7571f8b9728e5a0bae4eb6d2fdf5639a0c27b2c4c63c09f562a614c2` | Qualcomm WLAN driver 1.0.3710.9700 for the Galaxy Book2 Go (Windows Update 200.0.12.0), `wpss.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-sc7280-samsung-galaxy-book2-go`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
