# microsoft-surface-pro-12th-edition-firmware

Audio DSP and compute DSP firmware for the Microsoft Surface Pro 12th Edition, from Microsoft's own Windows driver download.

The firmware only runs if Microsoft signed it for this board, so linux-firmware cannot carry it until Microsoft submits it. The package holds no firmware itself. Its recipe downloads the driver package below when the package is built, unpacks it without running it, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

## Source

- [Surface Pro 12th Edition with Snapdragon](https://download.microsoft.com/download/85364b00-7e11-4a77-8115-bfcece673d91/SurfacePro12withSnapdragon_Win11_28000_26.091.14453.0.msi), 690 MB, SHA-256 `a35da2faa0af7c05b701ac9b451b70c335d8795b025427da082739b665d2a51a`, checked 2026-11-14. The link changes with every version, and [the download page](https://www.microsoft.com/en-us/download/details.aspx?id=108706) lists the current one.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/glymur/microsoft/surface-pro-12th-edition/adsp_dtbs.elf` | `03a76a8d9ed13cd904530880d7122f16cb81b63829c455e4af09d86ed69b3fe9` | Surface Pro 12th Edition with Snapdragon, `SurfaceUpdate/proextadsp8480/adsp_dtbs.elf` |
| `qcom/glymur/microsoft/surface-pro-12th-edition/adspr.jsn` | `e9ba7199626b0c03f2ec02822d744f678ad567fe0625a28fe5f5908b7281e9db` | Surface Pro 12th Edition with Snapdragon, `SurfaceUpdate/proextadsp8480/adspr.jsn` |
| `qcom/glymur/microsoft/surface-pro-12th-edition/adsps.jsn` | `19b1396b5e2c0d14fb8a4eb8e47181df7f62989f4af519b439cf0ee45a46f76e` | Surface Pro 12th Edition with Snapdragon, `SurfaceUpdate/proextadsp8480/adsps.jsn` |
| `qcom/glymur/microsoft/surface-pro-12th-edition/adspua.jsn` | `d65dc1aedce2c1131da8ffaed7dcffc05cc9c58da491e0c39acb2ac5b3f4bc1d` | Surface Pro 12th Edition with Snapdragon, `SurfaceUpdate/proextadsp8480/adspua.jsn` |
| `qcom/glymur/microsoft/surface-pro-12th-edition/cdsp_dtbs.elf` | `dfd345ab5ee9dba7fc7d717a35a3b9bb96f195a1d2cde18af41be1945d8599db` | Surface Pro 12th Edition with Snapdragon, `SurfaceUpdate/qcnspmcdm8480/cdsp_dtbs.elf` |
| `qcom/glymur/microsoft/surface-pro-12th-edition/qcadsp8480.mbn` | `f2d6dcb59218dbc1bf599af157f1de59ae04c8f1b0ac090f1f775c5f5631d351` | Surface Pro 12th Edition with Snapdragon, `SurfaceUpdate/proextadsp8480/qcadsp8480.mbn` |
| `qcom/glymur/microsoft/surface-pro-12th-edition/qccdsp8480.mbn` | `2798125b8458d47b4e1adbd3ae2451fdb20ee6add9ea4dc6211c96d96210a2b9` | Surface Pro 12th Edition with Snapdragon, `SurfaceUpdate/qcnspmcdm8480/qccdsp8480.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-glymur-microsoft-surface-pro-12th-edition`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
