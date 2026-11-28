# microsoft-surface-pro-x-firmware

Audio DSP, compute DSP, GPU, modem and sensor DSP firmware for the Microsoft Surface Pro X, from the driver bundle Microsoft publishes for it on Windows Update.

The firmware only runs if Microsoft signed it for this board, so linux-firmware cannot carry it until Microsoft submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Windows Update hands out short-lived links only, so a `wu://` source names the update ID, revision and SHA-1 of a file, and [wudrivers](https://github.com/birkskyum/wudrivers) fetches a fresh link for it when the package builds. makepkg then checks the file against its SHA-256 like any other source.

## Source

- Surface Pro X sensor DSP extension 1.0.710.2 for the Surface Pro X 1876 (Windows Update 200.0.61.0), `wu://df125451-24b9-4ec3-9b87-86bebbb064c2/1/e86bb4850df268590b9fce602e8eebd75a29ed48`, 2 MB, SHA-256 `13fea856ad45ae666673831389d1cbc7727526e3e40a8a61c770d5691b501e76`, checked 2026-11-15.
- Surface Pro X compute DSP extension 1.0.1660.1 for the Surface Pro X 1876 (Windows Update 200.0.61.0), `wu://df125451-24b9-4ec3-9b87-86bebbb064c2/1/d9caaa6b71a5bc445e90cd9848135261980d36db`, 3 MB, SHA-256 `d84fc7cde53735c37e2b3bb8fa2a979fa0d1eb9f5bf50beafd92246358320061`, checked 2026-11-15.
- Surface Pro X audio DSP extension 1.0.1980.1 for the Surface Pro X 1876 (Windows Update 200.0.61.0), `wu://df125451-24b9-4ec3-9b87-86bebbb064c2/1/215ef94c5066f2039171a06abc09068e03097345`, 7 MB, SHA-256 `437a9f6bdc25bfe5b46acbd718f417c1359ba24b8004f89a3a2cf95a69ba0aaf`, checked 2026-11-15.
- Surface Pro X modem extension 10400.4.78.0 for the Surface Pro X 2010 (Windows Update 200.0.33.0), `wu://8f9559e2-5ad6-4d58-9355-c2a8d5217d58/1/b58e93022ec1067ccd0020442cdc751ec09a9c5d`, 42 MB, SHA-256 `5cfe82260694636a9503acd1dd66b452240ea0fe55062d0f6330a50a34aa9fa3`, checked 2026-11-15.
- Qualcomm Adreno graphics driver 27.20.2140.0 for the Surface Pro X 1876 (Windows Update 200.0.61.0), `wu://df125451-24b9-4ec3-9b87-86bebbb064c2/1/1cac501c2fd734c75b26e5fda310dd3eaab43ed9`, 83 MB, SHA-256 `6214b56760cba1ece660c9c0f23dc15b1742299ae535df574ddd685a807679a3`, checked 2026-11-15.
- Qualcomm Adreno graphics driver 27.20.2160.0 for the Surface Pro X 2010 (Windows Update 200.0.33.0), `wu://8f9559e2-5ad6-4d58-9355-c2a8d5217d58/1/b60ed18da0abe6d749c8b8f8c69650fce60e8784`, 83 MB, SHA-256 `bfb3fdf600035d8b533639fed9207ecad15c74c432ad554e1ac57f199b57ffa8`, checked 2026-11-15.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/sc8180x/microsoft/cambria/qcadsp8180.mbn` | `09c06fe8e1c1e6c2c77cd2bbea754b34216a36f56ba9f9a7a3814cd2c31744d3` | Surface Pro X audio DSP extension 1.0.1980.1 for the Surface Pro X 1876 (Windows Update 200.0.61.0), `qcadsp8180.mbn` |
| `qcom/sc8180x/microsoft/cambria/qccdsp8180.mbn` | `2a276b79208e89c3299fa81a39ab47bc61a67b8ba13de2a5685f4a9d67d149c1` | Surface Pro X compute DSP extension 1.0.1660.1 for the Surface Pro X 1876 (Windows Update 200.0.61.0), `qccdsp8180.mbn` |
| `qcom/sc8180x/microsoft/cambria/qcdxkmsuc8180.mbn` | `9c47234c2ffcd5337b4dbf1d82bb587b99afb9e523af959cc9dbb1a6338e62a8` | Qualcomm Adreno graphics driver 27.20.2140.0 for the Surface Pro X 1876 (Windows Update 200.0.61.0), `qcdxkmsuc8180.mbn` |
| `qcom/sc8180x/microsoft/cambria/qcmpss8180.mbn` | `9ec7b6c6dae5d97af84ab71af6cb93b1892a4db1bd2b0b9de3e12a5d691a5439` | Surface Pro X modem extension 10400.4.78.0 for the Surface Pro X 2010 (Windows Update 200.0.33.0), `qcmpss8180.mbn` |
| `qcom/sc8180x/microsoft/cambria/qcslpi8180.mbn` | `7964ffba743cc6c1042faa21ae016c492a733f4de031a087ba2796b1ed354d50` | Surface Pro X sensor DSP extension 1.0.710.2 for the Surface Pro X 1876 (Windows Update 200.0.61.0), `qcslpi8180.mbn` |
| `qcom/sc8180x/microsoft/carina/qcadsp8180.mbn` | `09c06fe8e1c1e6c2c77cd2bbea754b34216a36f56ba9f9a7a3814cd2c31744d3` | Surface Pro X audio DSP extension 1.0.1980.1 for the Surface Pro X 1876 (Windows Update 200.0.61.0), `qcadsp8180.mbn` |
| `qcom/sc8180x/microsoft/carina/qccdsp8180.mbn` | `2a276b79208e89c3299fa81a39ab47bc61a67b8ba13de2a5685f4a9d67d149c1` | Surface Pro X compute DSP extension 1.0.1660.1 for the Surface Pro X 1876 (Windows Update 200.0.61.0), `qccdsp8180.mbn` |
| `qcom/sc8180x/microsoft/carina/qcdxkmsuc8180.mbn` | `9c47234c2ffcd5337b4dbf1d82bb587b99afb9e523af959cc9dbb1a6338e62a8` | Qualcomm Adreno graphics driver 27.20.2140.0 for the Surface Pro X 1876 (Windows Update 200.0.61.0), `qcdxkmsuc8180.mbn` |
| `qcom/sc8180x/microsoft/carina/qcmpss8180.mbn` | `9ec7b6c6dae5d97af84ab71af6cb93b1892a4db1bd2b0b9de3e12a5d691a5439` | Surface Pro X modem extension 10400.4.78.0 for the Surface Pro X 2010 (Windows Update 200.0.33.0), `qcmpss8180.mbn` |
| `qcom/sc8180x/microsoft/carina/qcslpi8180.mbn` | `7964ffba743cc6c1042faa21ae016c492a733f4de031a087ba2796b1ed354d50` | Surface Pro X sensor DSP extension 1.0.710.2 for the Surface Pro X 1876 (Windows Update 200.0.61.0), `qcslpi8180.mbn` |
| `qcom/sc8180x/microsoft/caspar/qcadsp8180.mbn` | `09c06fe8e1c1e6c2c77cd2bbea754b34216a36f56ba9f9a7a3814cd2c31744d3` | Surface Pro X audio DSP extension 1.0.1980.1 for the Surface Pro X 1876 (Windows Update 200.0.61.0), `qcadsp8180.mbn` |
| `qcom/sc8180x/microsoft/caspar/qccdsp8180.mbn` | `2a276b79208e89c3299fa81a39ab47bc61a67b8ba13de2a5685f4a9d67d149c1` | Surface Pro X compute DSP extension 1.0.1660.1 for the Surface Pro X 1876 (Windows Update 200.0.61.0), `qccdsp8180.mbn` |
| `qcom/sc8180x/microsoft/caspar/qcdxkmsuc8180.mbn` | `55306450faaa6b83cec437dc8a2e908baeed698087437f093c590136d2059020` | Qualcomm Adreno graphics driver 27.20.2160.0 for the Surface Pro X 2010 (Windows Update 200.0.33.0), `qcdxkmsuc8180.mbn` |
| `qcom/sc8180x/microsoft/caspar/qcmpss8180_nm.mbn` | `da7303ae94aee83f969c0218d8560b5de22119ac85b519117bafdc9ef5e3015c` | Surface Pro X modem extension 10400.4.78.0 for the Surface Pro X 2010 (Windows Update 200.0.33.0), `qcmpss8180_nm.mbn` |
| `qcom/sc8180x/microsoft/caspar/qcslpi8180.mbn` | `7964ffba743cc6c1042faa21ae016c492a733f4de031a087ba2796b1ed354d50` | Surface Pro X sensor DSP extension 1.0.710.2 for the Surface Pro X 1876 (Windows Update 200.0.61.0), `qcslpi8180.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-sc8180x-microsoft-cambria`, `qcom-firmware-sc8180x-microsoft-carina` and `qcom-firmware-sc8180x-microsoft-caspar`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
