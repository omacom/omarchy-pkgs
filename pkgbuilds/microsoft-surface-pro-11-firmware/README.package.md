# microsoft-surface-pro-11-firmware

Audio DSP, compute DSP, GPU and video firmware for the Microsoft Surface Pro 11th Edition, from Microsoft's own Windows driver download.

The firmware only runs if Microsoft signed it for this board, so linux-firmware cannot carry it until Microsoft submits it. The package holds no firmware itself. Its recipe downloads the driver package below when the package is built, unpacks it without running it, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

## Source

- [Surface Pro 11th Edition](https://download.microsoft.com/download/92821b24-203a-4ce5-9a3a-5df3160a2fe3/SurfacePro11_ARM_Win11_26100_26.094.41119.0.msi), 647 MB, SHA-256 `8b299016027a4a87f50cf168f69ca1fb8dedc9a0612fcd6cff89b9bc64135ec2`, checked 2026-11-02. The link changes with every version, and [the download page](https://www.microsoft.com/en-us/download/details.aspx?id=106119) lists the current one.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/x1e80100/microsoft/Denali/adsp_dtb.mbn` | `544bd795cb06cf8dee8119ede2a667f01066b2f1b9e4348f1772d080e2026ff4` | Surface Pro 11th Edition, `SurfaceUpdate/proextadsp/adsp_dtbs.elf` |
| `qcom/x1e80100/microsoft/Denali/adspr.jsn` | `e9ba7199626b0c03f2ec02822d744f678ad567fe0625a28fe5f5908b7281e9db` | Surface Pro 11th Edition, `SurfaceUpdate/proextadsp/adspr.jsn` |
| `qcom/x1e80100/microsoft/Denali/adsps.jsn` | `19b1396b5e2c0d14fb8a4eb8e47181df7f62989f4af519b439cf0ee45a46f76e` | Surface Pro 11th Edition, `SurfaceUpdate/proextadsp/adsps.jsn` |
| `qcom/x1e80100/microsoft/Denali/adspua.jsn` | `d65dc1aedce2c1131da8ffaed7dcffc05cc9c58da491e0c39acb2ac5b3f4bc1d` | Surface Pro 11th Edition, `SurfaceUpdate/proextadsp/adspua.jsn` |
| `qcom/x1e80100/microsoft/Denali/battmgr.jsn` | `b8aad1d149128f414eb1fd6fcbb6e0a5b7dabcd2cba001599e1ce9a0e2e291a4` | Surface Pro 11th Edition, `SurfaceUpdate/proextadsp/battmgr.jsn` |
| `qcom/x1e80100/microsoft/Denali/cdsp_dtb.mbn` | `93941f040da14b8305d39579686d886706d22954a538b03da676c1aaa191797f` | Surface Pro 11th Edition, `SurfaceUpdate/qcnspmcdmextcdsp8380/cdsp_dtbs.elf` |
| `qcom/x1e80100/microsoft/Denali/cdspr.jsn` | `7e46c515ab1bb012768be6e961eca69b1c8aad9af1cbac886b3b5ae8d4228f64` | Surface Pro 11th Edition, `SurfaceUpdate/qcnspmcdmextcdsp8380/cdspr.jsn` |
| `qcom/x1e80100/microsoft/Denali/qcadsp8380.mbn` | `921870a839ee2aba647b04598d62ed96f3d2d5dfbb2499fc842f9a6ff0e0da13` | Surface Pro 11th Edition, `SurfaceUpdate/proextadsp/qcadsp8380.mbn` |
| `qcom/x1e80100/microsoft/Denali/qccdsp8380.mbn` | `4a67a03367f2eff2f8a0e867ca25d2bf2fcd5aee3e41e2c9f436c804e257c789` | Surface Pro 11th Edition, `SurfaceUpdate/qcnspmcdmextcdsp8380/qccdsp8380.mbn` |
| `qcom/x1e80100/microsoft/Denali/qcvss8380.mbn` | `2e37684e8c84b7d945396da24c295c3267e97087a537386bb10ad1fa5ef85ebc` | Surface Pro 11th Edition, `SurfaceUpdate/qcdx/qcvss8380.mbn` |
| `qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn` | `c89711a60240f29cb5df13f7b904642b78b7d9d6e614473751f7bf4049fab137` | Surface Pro 11th Edition, `SurfaceUpdate/qcdx/qcdxkmsuc8380.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-x1e80100-microsoft-denali` and `qcom-firmware-x1e80100-microsoft`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
