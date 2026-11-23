# acer-spin-7-firmware

Audio DSP, compute DSP, GPU and modem firmware for the Acer Spin 7 SP714-61NA, from the driver bundle Acer publishes for it on Windows Update.

The firmware only runs if Acer signed it for this board, so linux-firmware cannot carry it until Acer submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Windows Update hands out short-lived links only, so a `wu://` source names the update ID, revision and SHA-1 of a file, and [wudrivers](https://github.com/birkskyum/wudrivers) fetches a fresh link for it when the package builds. makepkg then checks the file against its SHA-256 like any other source.

## Source

- Qualcomm WLAN driver 1.0.1420.0000 for the Acer Spin 7 SP714-61NA (Windows Update 200.0.10.0), `wu://76598104-93f0-4b68-b903-dc959c4b1073/1/919376ee2da212dd43459262aae946897e08392c`, 2 MB, SHA-256 `3b2e60d1d2560bd419664f4449216deb01be149fc92982d0898a8089ae79a0c2`, checked 2026-11-16.
- Qualcomm Compute DSP Subsystem extension 1.0.1430.0000 for the Acer Spin 7 SP714-61NA (Windows Update 200.0.10.0), `wu://76598104-93f0-4b68-b903-dc959c4b1073/1/b6f1388e8151a54c49ac43e0a0e87d577fa27621`, 3 MB, SHA-256 `38fae7299f1caeb0024af21c46ea62c529da5803243694d79c02aeb790fda54e`, checked 2026-11-16.
- Qualcomm Audio DSP Subsystem extension 1.0.1460.0000 for the Acer Spin 7 SP714-61NA (Windows Update 200.0.10.0), `wu://76598104-93f0-4b68-b903-dc959c4b1073/1/81b40fa29e21b2c6ed6135e2fb1291a82cd7c7e6`, 7 MB, SHA-256 `b5002d6f76268ad56d83288dd401c1e32759749d999a93c0b4daf07213fce06f`, checked 2026-11-16.
- Qualcomm Adreno graphics driver 27.20.1460.0000 for the Acer Spin 7 SP714-61NA (Windows Update 200.0.10.0), `wu://76598104-93f0-4b68-b903-dc959c4b1073/1/0cc89ff2ec57ee1fe1f1a83897ad24e20769ca44`, 32 MB, SHA-256 `3e269d0384979319518ea2d55f1c5f57726a90ec1a1e46caa9ea8fabccecb1c8`, checked 2026-11-16.
- Qualcomm Modem Subsystem extension 1.0.1430.0000 for the Acer Spin 7 SP714-61NA (Windows Update 200.0.10.0), `wu://76598104-93f0-4b68-b903-dc959c4b1073/1/94c43f41885ff179033aa255463945c7a4f2074a`, 36 MB, SHA-256 `0076174aa398e4c4eef3ec70936c594fb3e41a9c4e0fd67fd5a438534c516643`, checked 2026-11-16.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/sc8180xp/Acer/SP714-61NA/qcadsp8180.mbn` | `8220e7e61e8b685c1ed2ce2e4a259bded36a2050de571671ef73d8889cfdd73f` | Qualcomm Audio DSP Subsystem extension 1.0.1460.0000 for the Acer Spin 7 SP714-61NA (Windows Update 200.0.10.0), `qcadsp8180.mbn` |
| `qcom/sc8180xp/Acer/SP714-61NA/qccdsp8180.mbn` | `7c146e68f4b3a80ccbc03539e38440c69da4ce4c9e0a8feb74e6d21feb837a33` | Qualcomm Compute DSP Subsystem extension 1.0.1430.0000 for the Acer Spin 7 SP714-61NA (Windows Update 200.0.10.0), `qccdsp8180.mbn` |
| `qcom/sc8180xp/Acer/SP714-61NA/qcdxkmsuc8180.mbn` | `416f200c6bbf9bf3685b332848e733e56f4944954271be9195e9636573002493` | Qualcomm Adreno graphics driver 27.20.1460.0000 for the Acer Spin 7 SP714-61NA (Windows Update 200.0.10.0), `qcdxkmsuc8180.mbn` |
| `qcom/sc8180xp/Acer/SP714-61NA/qcmpss8180_nm.mbn` | `fc819b43e639212d9f32a5c356db26aaef6ba0cf89aa7392575b735ac76b2c92` | Qualcomm Modem Subsystem extension 1.0.1430.0000 for the Acer Spin 7 SP714-61NA (Windows Update 200.0.10.0), `qcmpss8180_nm.mbn` |
| `qcom/sc8180xp/Acer/SP714-61NA/wlanmdsp.mbn` | `f3f9a8929a4911d7eef42058081db348d22cb96a9d00b0adba70587a7bd7dc50` | Qualcomm WLAN driver 1.0.1420.0000 for the Acer Spin 7 SP714-61NA (Windows Update 200.0.10.0), `WLANMDSP.MBN` |

## How Omarchy installs it

The package provides `qcom-firmware-sc8180xp-acer-sp714-61na`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
