# hp-omnibook-x16-cp0-firmware

Audio DSP, compute DSP and GPU firmware for the HP OmniBook X 14 and 16 (2025), from HP's own Windows driver download.

The firmware only runs if HP signed it for this board, so linux-firmware cannot carry it until HP submits it. The package holds no firmware itself. Its recipe downloads the driver package below when the package is built, unpacks it without running it, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Its files are byte for byte the ones in `qcom/x1p42100/hp/omnibook-5`, which the table links them to as linux-firmware's WHENCE would, so the recipe can take them from another machine's download, the smallest that holds them.

## Source

- [Qualcomm Driver Pack sp173598](https://ftp.hp.com/pub/softpaq/sp173501-174000/sp173598.exe), 240 MB, SHA-256 `920af92f223626a568d0c66ef5c0439efb5876937a515d9acf74dba35b1a2dd8`, checked 2026-11-02.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/x1p42100/hp/omnibook-x16-cp0/adsp_dtbs.elf` | `65d545429dc8cc58860799e5006373cc140884d1a8ea1fbb0b78861533f15404` | Qualcomm Driver Pack sp173598, `src/OSPart/qcsubsys_ext_adsp8380_DUA_Efuse_WHQL/adsp_dtbs.elf` |
| `qcom/x1p42100/hp/omnibook-x16-cp0/adspr.jsn` | `e9ba7199626b0c03f2ec02822d744f678ad567fe0625a28fe5f5908b7281e9db` | Qualcomm Driver Pack sp173598, `src/OSPart/qcsubsys_ext_adsp8380_DUA_Efuse_WHQL/adspr.jsn` |
| `qcom/x1p42100/hp/omnibook-x16-cp0/adsps.jsn` | `19b1396b5e2c0d14fb8a4eb8e47181df7f62989f4af519b439cf0ee45a46f76e` | Qualcomm Driver Pack sp173598, `src/OSPart/qcsubsys_ext_adsp8380_DUA_Efuse_WHQL/adsps.jsn` |
| `qcom/x1p42100/hp/omnibook-x16-cp0/adspua.jsn` | `d65dc1aedce2c1131da8ffaed7dcffc05cc9c58da491e0c39acb2ac5b3f4bc1d` | Qualcomm Driver Pack sp173598, `src/OSPart/qcsubsys_ext_adsp8380_DUA_Efuse_WHQL/adspua.jsn` |
| `qcom/x1p42100/hp/omnibook-x16-cp0/battmgr.jsn` | `b8aad1d149128f414eb1fd6fcbb6e0a5b7dabcd2cba001599e1ce9a0e2e291a4` | Qualcomm Driver Pack sp173598, `src/OSPart/qcsubsys_ext_adsp8380_DUA_Efuse_WHQL/battmgr.jsn` |
| `qcom/x1p42100/hp/omnibook-x16-cp0/cdsp_dtbs.elf` | `8880a7a2252e7951b1bc7c14869c8c37062583ba26b21fee6194c593e3447a7e` | Qualcomm Driver Pack sp173598, `src/OSPart/qcnspmcdm_ext_cdsp8380/cdsp_dtbs.elf` |
| `qcom/x1p42100/hp/omnibook-x16-cp0/cdspr.jsn` | `7e46c515ab1bb012768be6e961eca69b1c8aad9af1cbac886b3b5ae8d4228f64` | Qualcomm Driver Pack sp173598, `src/OSPart/qcnspmcdm_ext_cdsp8380/cdspr.jsn` |
| `qcom/x1p42100/hp/omnibook-x16-cp0/qcadsp8380.mbn` | `bfd20acacaa2c4323650652a25db0e0a4ad01ed98e46c269c6850569d4e8421d` | Qualcomm Driver Pack sp173598, `src/OSPart/qcsubsys_ext_adsp8380_DUA_Efuse_WHQL/qcadsp8380.mbn` |
| `qcom/x1p42100/hp/omnibook-x16-cp0/qccdsp8380.mbn` | `8a4465f747dbf43441fdba7d5c0312057d2cd1bb1e42cb4833d9ebdb7253388e` | Qualcomm Driver Pack sp173598, `src/OSPart/qcnspmcdm_ext_cdsp8380/qccdsp8380.mbn` |
| `qcom/x1p42100/hp/omnibook-x16-cp0/qcdxkmsucpurwa.mbn` | `63d53b1908d2c053099680e4403b410a3f59f18ecd395586bb3d2ed33a86fea6` | Qualcomm Driver Pack sp173598, `src/OSPart/qcdx8380/qcdxkmsucpurwa.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-x1p42100-hp-omnibook-x16-cp0`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
