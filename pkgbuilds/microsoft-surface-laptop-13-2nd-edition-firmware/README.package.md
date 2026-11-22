# microsoft-surface-laptop-13-2nd-edition-firmware

Audio DSP and compute DSP firmware for the Microsoft Surface Laptop 13-inch 2nd Edition, from Microsoft's own Windows driver download.

The firmware only runs if Microsoft signed it for this board, so linux-firmware cannot carry it until Microsoft submits it. The package holds no firmware itself. Its recipe downloads the driver package below when the package is built, unpacks it without running it, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

## Source

- [Surface Laptop 13-inch 2nd Edition with Snapdragon](https://download.microsoft.com/download/30ff24b5-e65e-4fde-9c22-491e6ac81c16/SurfaceLaptop13in2ndEditionwithSnapdragon_Win11_28000_26.083.37733.0.msi), 687 MB, SHA-256 `6301570ca49f810c6b63b0eb5c2f729bb3072508e42cdfa980be65af8f1950ef`, checked 2026-11-14. The link changes with every version, and [the download page](https://www.microsoft.com/en-us/download/details.aspx?id=108876) lists the current one.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/kalambo/Microsoft/SurfaceLaptop13/adsp_dtbs.elf` | `dc2230da43b08c8c0fdf80a27f73d69a2acd74e98eec2462480220d71b20c6d6` | Surface Laptop 13-inch 2nd Edition with Snapdragon, `SurfaceUpdate/proextadsp8480/adsp_dtbs.elf` |
| `qcom/kalambo/Microsoft/SurfaceLaptop13/adspr.jsn` | `e9ba7199626b0c03f2ec02822d744f678ad567fe0625a28fe5f5908b7281e9db` | Surface Laptop 13-inch 2nd Edition with Snapdragon, `SurfaceUpdate/proextadsp8480/adspr.jsn` |
| `qcom/kalambo/Microsoft/SurfaceLaptop13/adsps.jsn` | `19b1396b5e2c0d14fb8a4eb8e47181df7f62989f4af519b439cf0ee45a46f76e` | Surface Laptop 13-inch 2nd Edition with Snapdragon, `SurfaceUpdate/proextadsp8480/adsps.jsn` |
| `qcom/kalambo/Microsoft/SurfaceLaptop13/adspua.jsn` | `d65dc1aedce2c1131da8ffaed7dcffc05cc9c58da491e0c39acb2ac5b3f4bc1d` | Surface Laptop 13-inch 2nd Edition with Snapdragon, `SurfaceUpdate/proextadsp8480/adspua.jsn` |
| `qcom/kalambo/Microsoft/SurfaceLaptop13/cdsp_dtbs.elf` | `dfd345ab5ee9dba7fc7d717a35a3b9bb96f195a1d2cde18af41be1945d8599db` | Surface Laptop 13-inch 2nd Edition with Snapdragon, `SurfaceUpdate/qcnspmcdm8480/cdsp_dtbs.elf` |
| `qcom/kalambo/Microsoft/SurfaceLaptop13/qcadsp8480.mbn` | `4755dc27cf447fa2f54236c33d16434d8223971b1c0b364f03fa2afba45499f2` | Surface Laptop 13-inch 2nd Edition with Snapdragon, `SurfaceUpdate/proextadsp8480/qcadsp8480.mbn` |
| `qcom/kalambo/Microsoft/SurfaceLaptop13/qccdsp8480.mbn` | `2798125b8458d47b4e1adbd3ae2451fdb20ee6add9ea4dc6211c96d96210a2b9` | Surface Laptop 13-inch 2nd Edition with Snapdragon, `SurfaceUpdate/qcnspmcdm8480/qccdsp8480.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-kalambo-microsoft-surfacelaptop13`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
