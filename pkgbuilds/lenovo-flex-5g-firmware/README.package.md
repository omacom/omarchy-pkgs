# lenovo-flex-5g-firmware

Audio DSP, compute DSP, GPU and modem firmware for the Lenovo Flex 5G and Yoga 5G, from the driver bundle Lenovo publishes for it on Windows Update.

The firmware only runs if Lenovo signed it for this board, so linux-firmware cannot carry it until Lenovo submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Windows Update hands out short-lived links only, so a `wu://` source names the update ID, revision and SHA-1 of a file, and [wudrivers](https://github.com/birkskyum/wudrivers) fetches a fresh link for it when the package builds. makepkg then checks the file against its SHA-256 like any other source.

## Source

- Qualcomm Compute DSP Subsystem extension 1.0.1430.0000 for the 82AK (Windows Update 200.0.11.0), `wu://c1bb02d4-f34d-46bc-9603-5117190782f3/1/b6f1388e8151a54c49ac43e0a0e87d577fa27621`, 3 MB, SHA-256 `38fae7299f1caeb0024af21c46ea62c529da5803243694d79c02aeb790fda54e`, checked 2026-11-15.
- Qualcomm Audio DSP Subsystem extension 1.0.1460.0000 for the 82AK (Windows Update 200.0.11.0), `wu://c1bb02d4-f34d-46bc-9603-5117190782f3/1/425da23f481e7d189708f17ab006efc777f4ea49`, 7 MB, SHA-256 `aa62164ef193d36ff2b8dfb008e07dc312cd79d280ae53166d9a94de6ed95426`, checked 2026-11-15.
- Qualcomm Adreno graphics driver 27.20.1460.0000 for the 82AK (Windows Update 200.0.11.0), `wu://c1bb02d4-f34d-46bc-9603-5117190782f3/1/0cc89ff2ec57ee1fe1f1a83897ad24e20769ca44`, 32 MB, SHA-256 `3e269d0384979319518ea2d55f1c5f57726a90ec1a1e46caa9ea8fabccecb1c8`, checked 2026-11-15.
- Qualcomm Modem Subsystem extension 1.0.1430.0000 for the 82AK (Windows Update 200.0.11.0), `wu://c1bb02d4-f34d-46bc-9603-5117190782f3/1/94c43f41885ff179033aa255463945c7a4f2074a`, 36 MB, SHA-256 `0076174aa398e4c4eef3ec70936c594fb3e41a9c4e0fd67fd5a438534c516643`, checked 2026-11-15.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/sc8180x/LENOVO/82AK/qcadsp8180.mbn` | `23351f379a9cca01a28cee7be0b88c93c76b445d7f38853d592dbca9005bb18e` | Qualcomm Audio DSP Subsystem extension 1.0.1460.0000 for the 82AK (Windows Update 200.0.11.0), `qcadsp8180.mbn` |
| `qcom/sc8180x/LENOVO/82AK/qccdsp8180.mbn` | `7c146e68f4b3a80ccbc03539e38440c69da4ce4c9e0a8feb74e6d21feb837a33` | Qualcomm Compute DSP Subsystem extension 1.0.1430.0000 for the 82AK (Windows Update 200.0.11.0), `qccdsp8180.mbn` |
| `qcom/sc8180x/LENOVO/82AK/qcdxkmsuc8180.mbn` | `416f200c6bbf9bf3685b332848e733e56f4944954271be9195e9636573002493` | Qualcomm Adreno graphics driver 27.20.1460.0000 for the 82AK (Windows Update 200.0.11.0), `qcdxkmsuc8180.mbn` |
| `qcom/sc8180x/LENOVO/82AK/qcmpss8180_nm.mbn` | `fc819b43e639212d9f32a5c356db26aaef6ba0cf89aa7392575b735ac76b2c92` | Qualcomm Modem Subsystem extension 1.0.1430.0000 for the 82AK (Windows Update 200.0.11.0), `qcmpss8180_nm.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-sc8180x-lenovo-82ak`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
