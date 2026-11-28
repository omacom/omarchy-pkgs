# hp-elitebook-6-g2q-firmware

Audio DSP and compute DSP firmware for the HP EliteBook 6 G2q, from HP's own Windows driver download.

The firmware only runs if HP signed it for this board, so linux-firmware cannot carry it until HP submits it. The package holds no firmware itself. Its recipe downloads the driver package below when the package is built, unpacks it without running it, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

## Source

- [Qualcomm BSP Software Pack sp174817](https://ftp.hp.com/pub/softpaq/sp174501-175000/sp174817.exe), 298 MB, SHA-256 `618091167b61fb9773a81c91dc4ea93ba0837b3cd2ad0ad81263abb529a60bea`, checked 2026-11-14.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/glymur/hp/elitebook-6-g2q/adsp_dtbs.elf` | `00bf5b3216feeb47b2a9be06b86190ff1da16b28f80be710968c379341a7fbac` | Qualcomm BSP Software Pack sp174817, `src/driver/regrouped_driver/qcsubsys_ext_adsp8480/adsp_dtbs.elf` |
| `qcom/glymur/hp/elitebook-6-g2q/adspr.jsn` | `66ce8531efb7979d234e0f0eabbe18d038ac97da771a8a194f613df8f0724e81` | Qualcomm BSP Software Pack sp174817, `src/driver/regrouped_driver/qcsubsys_ext_adsp8480/adspr.jsn` |
| `qcom/glymur/hp/elitebook-6-g2q/adsps.jsn` | `12ac2f3ae8ced12aa4b06b3ab3a01bc4d8efe1c92ebea503c002f209a6ec176f` | Qualcomm BSP Software Pack sp174817, `src/driver/regrouped_driver/qcsubsys_ext_adsp8480/adsps.jsn` |
| `qcom/glymur/hp/elitebook-6-g2q/adspua.jsn` | `982a99853495e34726b8e44697fdfad303334de0a67cbf6cde306c8f1731000b` | Qualcomm BSP Software Pack sp174817, `src/driver/regrouped_driver/qcsubsys_ext_adsp8480/adspua.jsn` |
| `qcom/glymur/hp/elitebook-6-g2q/cdsp_dtbs.elf` | `a10da41b26547dd88f9287f66cf92cd8ba17cc1dce5eeff4d46621c3ae2258c2` | Qualcomm BSP Software Pack sp174817, `src/driver/regrouped_driver/qcnspmcdm8480/cdsp_dtbs.elf` |
| `qcom/glymur/hp/elitebook-6-g2q/qcadsp8480.mbn` | `75ecf1c174a62d116a9e510083cecca817d93a5cb24dc229110dc2ace74d5501` | Qualcomm BSP Software Pack sp174817, `src/driver/regrouped_driver/qcsubsys_ext_adsp8480/qcadsp8480.mbn` |
| `qcom/glymur/hp/elitebook-6-g2q/qccdsp8480.mbn` | `fae8fb92104ce23839ec384eea83c01be7fe92d0b7d5329b9a200b9b3ab83986` | Qualcomm BSP Software Pack sp174817, `src/driver/regrouped_driver/qcnspmcdm8480/qccdsp8480.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-glymur-hp-elitebook-6-g2q`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
