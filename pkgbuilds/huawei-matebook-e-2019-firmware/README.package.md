# huawei-matebook-e-2019-firmware

Audio DSP, compute DSP, GPU, video, modem and sensor DSP firmware for the Huawei MateBook E 2019, from the driver bundle Huawei publishes for it on Windows Update.

The firmware only runs if Huawei signed it for this board, so linux-firmware cannot carry it until Huawei submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Windows Update hands out short-lived links only, so a `wu://` source names the update ID, revision and SHA-1 of a file, and [wudrivers](https://github.com/birkskyum/wudrivers) fetches a fresh link for it when the package builds. makepkg then checks the file against its SHA-256 like any other source.

## Source

- Qualcomm Subsystem driver 1.0.10450.0010 for the MateBook E 2019 (Windows Update 200.0.4.0), `wu://3bbce7bf-87ca-4480-965b-b0205cec89a9/1/3b032f6f147338e917c615703361e36f4d91c419`, 75 MB, SHA-256 `6de57d307518df6505532b7ea845ea3b5d20f8049110230fff2921e280141676`, checked 2026-11-16.
- Qualcomm Adreno graphics driver 25.18.10500.0000 for the MateBook E 2019 (Windows Update 200.0.4.0), `wu://3bbce7bf-87ca-4480-965b-b0205cec89a9/1/edc61f1e44bcc04e20fff33d6ebc37d196b3a42b`, 30 MB, SHA-256 `9ba61abb3a42865debe4f802ad78513b24bb5803d7dbb1cad02dbc31585136d9`, checked 2026-11-16.
- Qualcomm IPA driver 1.0.10440.0000 for the MateBook E 2019 (Windows Update 200.0.4.0), `wu://3bbce7bf-87ca-4480-965b-b0205cec89a9/1/43ea42ded714b480ca1b578df885f8342dd128a9`, 1 MB, SHA-256 `e700987849b7212f0c6bbc0e0ea928f2fc118d1a213dba2841e0ca2bc62a61db`, checked 2026-11-16.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/sdm850/HUAWEI/AL09/ipa_fws.elf` | `ae61edebe69cea9a64d9b7080a481fc305f69da265197df180c3cc90aab9d68d` | Qualcomm IPA driver 1.0.10440.0000 for the MateBook E 2019 (Windows Update 200.0.4.0), `ipa_fws.elf` |
| `qcom/sdm850/HUAWEI/AL09/qcadsp850.mbn` | `8c7655f9a8c3ae81852894de4cf0a2051bddb4efdc194359366eb5f1a82a2c1f` | Qualcomm Subsystem driver 1.0.10450.0010 for the MateBook E 2019 (Windows Update 200.0.4.0), `qcadsp850.mbn` |
| `qcom/sdm850/HUAWEI/AL09/qccdsp850.mbn` | `989de066b3d7ea1b893c83a8eaf559e90af518f4f95d816ca6b8b92ad36ba18c` | Qualcomm Subsystem driver 1.0.10450.0010 for the MateBook E 2019 (Windows Update 200.0.4.0), `qccdsp850.mbn` |
| `qcom/sdm850/HUAWEI/AL09/qcdsp1v2850.mbn` | `08647b92d864831889cd9f55762c967ddc3d3533bc2e8b32cd04920b8a13bcfa` | Qualcomm Subsystem driver 1.0.10450.0010 for the MateBook E 2019 (Windows Update 200.0.4.0), `qcdsp1v2850.mbn` |
| `qcom/sdm850/HUAWEI/AL09/qcdsp2850.mbn` | `08c3d83addcf0a4b05b14e95a17f0ed7c948c2a5633ff742136502ec99c9383b` | Qualcomm Subsystem driver 1.0.10450.0010 for the MateBook E 2019 (Windows Update 200.0.4.0), `qcdsp2850.mbn` |
| `qcom/sdm850/HUAWEI/AL09/qcdxkmsuc850.mbn` | `ca1276cf1a66d5207623eeb16c8a17e311cd9f39b24b9db6b43977a0902c3936` | Qualcomm Adreno graphics driver 25.18.10500.0000 for the MateBook E 2019 (Windows Update 200.0.4.0), `qcdxkmsuc850.mbn` |
| `qcom/sdm850/HUAWEI/AL09/qcslpi850.mbn` | `2a9044178a59dbd71fd88c3f319b119efae72b091bda930d31de8c9c55aa6956` | Qualcomm Subsystem driver 1.0.10450.0010 for the MateBook E 2019 (Windows Update 200.0.4.0), `qcslpi850.mbn` |
| `qcom/sdm850/HUAWEI/AL09/qcvss850.mbn` | `67e9173754ac4fbfb00df28111706791256c166cd1fab9885bbefa727c506588` | Qualcomm Adreno graphics driver 25.18.10500.0000 for the MateBook E 2019 (Windows Update 200.0.4.0), `qcvss850.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-sdm850-huawei-al09`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
