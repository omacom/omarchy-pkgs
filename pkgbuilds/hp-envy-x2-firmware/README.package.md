# hp-envy-x2-firmware

Audio DSP, video, modem and sensor DSP firmware for the HP Envy x2, from the driver bundle HP publishes for it on Windows Update.

The firmware only runs if HP signed it for this board, so linux-firmware cannot carry it until HP submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Windows Update hands out short-lived links only, so a `wu://` source names the update ID, revision and SHA-1 of a file, and [wudrivers](https://github.com/birkskyum/wudrivers) fetches a fresh link for it when the package builds. makepkg then checks the file against its SHA-256 like any other source.

## Source

- Qualcomm Subsystem driver 2.0.1083.0000 for the HP Envy x2 (Windows Update 200.0.5.0), `wu://55a6f81d-43c8-4594-9db5-11f82d7e04b5/1/d8f6303cd7cefbb74ff8a784c797b4f133aaf22a`, 77 MB, SHA-256 `b3854900c491fd36177b9fa51826a0c609cfbc485868501742be4cbd9d64c671`, checked 2026-11-16.
- Qualcomm Adreno graphics driver 22.18.1083.0000 for the HP Envy x2 (Windows Update 200.0.5.0), `wu://55a6f81d-43c8-4594-9db5-11f82d7e04b5/1/c227709ecf488899d8c95ad12aa1ca0341a570e4`, 27 MB, SHA-256 `94a28ad6da0d185a194792248d2a6b5ea38e99b0deab194d17d0e0d7b9ec6eca`, checked 2026-11-16.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/msm8998/hp/envy-x2/qcadsp8998.mbn` | `dcd8e66d919a4a1a2b6794627ed3f0a0712af0795dd73ac90169b6fbabc439d1` | Qualcomm Subsystem driver 2.0.1083.0000 for the HP Envy x2 (Windows Update 200.0.5.0), `qcadsp8998.mbn` |
| `qcom/msm8998/hp/envy-x2/qcdsp1v28998.mbn` | `b729eab69e1a20ed100f35fbd7ab3ccaca3f8077d85221a8225622e765f125e2` | Qualcomm Subsystem driver 2.0.1083.0000 for the HP Envy x2 (Windows Update 200.0.5.0), `qcdsp1v28998.mbn` |
| `qcom/msm8998/hp/envy-x2/qcdsp28998.mbn` | `b7a8fec6292f3fdaf6e40d20eb5158e460928396cd30ed785012146243c9050c` | Qualcomm Subsystem driver 2.0.1083.0000 for the HP Envy x2 (Windows Update 200.0.5.0), `qcdsp28998.mbn` |
| `qcom/msm8998/hp/envy-x2/qcslpi8998_CLS.mbn` | `ef97fec85d8400aa77b0366adfa5a931c846df70b1a36586d53a3bd2a7ab6cee` | Qualcomm Subsystem driver 2.0.1083.0000 for the HP Envy x2 (Windows Update 200.0.5.0), `qcslpi8998_CLS.mbn` |
| `qcom/msm8998/hp/envy-x2/qcvss8998.mbn` | `b74c650eb87e127973e50b185f504e26777c6b13b3a1b237f3a0a38573cca96d` | Qualcomm Adreno graphics driver 22.18.1083.0000 for the HP Envy x2 (Windows Update 200.0.5.0), `qcvss8998.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-msm8998-hp-envy-x2`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
