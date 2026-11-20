# lenovo-miix-630-firmware

Audio DSP, video, modem and sensor DSP firmware for the Lenovo Miix 630, from the driver bundle Lenovo publishes for it on Windows Update.

The firmware only runs if Lenovo signed it for this board, so linux-firmware cannot carry it until Lenovo submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Windows Update hands out short-lived links only, so a `wu://` source names the update ID, revision and SHA-1 of a file, and [wudrivers](https://github.com/birkskyum/wudrivers) fetches a fresh link for it when the package builds. makepkg then checks the file against its SHA-256 like any other source.

## Source

- Qualcomm Subsystem driver 2.0.1075.0009 for the 81F1 (Windows Update 200.0.6.0), `wu://b35ca847-d890-43ab-91c3-858924b39741/1/d755c12923fbf74d32dcddf6179e428b96d7f99e`, 77 MB, SHA-256 `13c356d1e716ce6b3457d4e74eec8dd0c7e9916b534d273c27430df03317ecd5`, checked 2026-11-15.
- Qualcomm Adreno graphics driver 22.18.1083.0000 for the 81F1 (Windows Update 200.0.6.0), `wu://b35ca847-d890-43ab-91c3-858924b39741/1/8961681f6435a99e58354a7c54d8017afab3ab71`, 27 MB, SHA-256 `72689ef44a7eae8be5a6eb81a0ee3dc372cfbef988c3f3f39b4ab985b2d2bc4e`, checked 2026-11-15.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/msm8998/LENOVO/81F1/qcadsp8998.mbn` | `3d1abb4d4686e2877126d845c2e5b2b0d7ee034fe2faf8a01aa8db2e4d02fc13` | Qualcomm Subsystem driver 2.0.1075.0009 for the 81F1 (Windows Update 200.0.6.0), `qcadsp8998.mbn` |
| `qcom/msm8998/LENOVO/81F1/qcdsp1v28998.mbn` | `0c3b54feea9a6fa0afb76f19f54431ef775dbbef6a2bef5e5dff7537609bb3f7` | Qualcomm Subsystem driver 2.0.1075.0009 for the 81F1 (Windows Update 200.0.6.0), `qcdsp1v28998.mbn` |
| `qcom/msm8998/LENOVO/81F1/qcdsp28998.mbn` | `4abbf58e88c18885264d3d7552d5cc43bd25bcc6c6bd23ecfbe20a1d758ce8be` | Qualcomm Subsystem driver 2.0.1075.0009 for the 81F1 (Windows Update 200.0.6.0), `qcdsp28998.mbn` |
| `qcom/msm8998/LENOVO/81F1/qcslpi8998.mbn` | `42ce2584bb7809ebce958e3e5ebfa4acf8360412b8e9d48d7bda790e11d9ed54` | Qualcomm Subsystem driver 2.0.1075.0009 for the 81F1 (Windows Update 200.0.6.0), `qcslpi8998.mbn` |
| `qcom/msm8998/LENOVO/81F1/qcvss8998.mbn` | `5536f18357f0c495eec416c5bbcae3b44970eaa9139e3e56c3feb6064312a334` | Qualcomm Adreno graphics driver 22.18.1083.0000 for the 81F1 (Windows Update 200.0.6.0), `qcvss8998.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-msm8998-lenovo-81f1`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
