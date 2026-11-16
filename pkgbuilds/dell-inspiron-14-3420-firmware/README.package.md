# dell-inspiron-14-3420-firmware

Audio DSP and GPU firmware for the Dell Inspiron 14 3420, from the driver bundle Dell publishes for it on Windows Update.

The firmware only runs if Dell signed it for this board, so linux-firmware cannot carry it until Dell submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Windows Update hands out short-lived links only, so a `wu://` source names the update ID, revision and SHA-1 of a file, and [wudrivers](https://github.com/birkskyum/wudrivers) fetches a fresh link for it when the package builds. makepkg then checks the file against its SHA-256 like any other source.

## Source

- Qualcomm Audio DSP Subsystem extension 1.0.1840.0006 for the Dell Inspiron 14 3420 (Windows Update 200.0.14.0), `wu://c9d649d1-623a-4ba9-8f0d-34c2350ce7b8/1/fcd67a39e6739cb30e46e74e70855cc4ee41b724`, 7 MB, SHA-256 `df4d3c133a5c0625841238c0441bc8dec283684014f80599f37daf679e8a107e`, checked 2026-11-16.
- Qualcomm Adreno graphics driver 27.20.1870.0 for the Dell Inspiron 14 3420 (Windows Update 200.0.14.0), `wu://c9d649d1-623a-4ba9-8f0d-34c2350ce7b8/1/21798db4aed1ee61f8552148a001173f362ebd2d`, 81 MB, SHA-256 `83cccbc83fb8166f4448567e498b4e04d3fb57fd9f4a5a726422c4c586060198`, checked 2026-11-16.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/sc8180xp/dell/qcadsp8180.mbn` | `2b9836033f37cc860fdbd9a26a2d5360bb4914fa75fdb1f784a0781d43075c64` | Qualcomm Audio DSP Subsystem extension 1.0.1840.0006 for the Dell Inspiron 14 3420 (Windows Update 200.0.14.0), `qcadsp8180.mbn` |
| `qcom/sc8180xp/dell/qcdxkmsuc8180.mbn` | `0170fbea8a31fe7c691b95f9b9e8ad720fde5ea23e3c91c0f5fbe0ebaa0d8213` | Qualcomm Adreno graphics driver 27.20.1870.0 for the Dell Inspiron 14 3420 (Windows Update 200.0.14.0), `qcdxkmsuc8180.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-sc8180xp-dell`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
