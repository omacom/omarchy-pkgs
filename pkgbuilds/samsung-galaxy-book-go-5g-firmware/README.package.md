# samsung-galaxy-book-go-5g-firmware

Audio DSP, compute DSP, GPU and modem firmware for the Samsung Galaxy Book Go 5G, from the driver bundle Samsung publishes for it on Windows Update.

The firmware only runs if Samsung signed it for this board, so linux-firmware cannot carry it until Samsung submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Windows Update hands out short-lived links only, so a `wu://` source names the update ID, revision and SHA-1 of a file, and [wudrivers](https://github.com/birkskyum/wudrivers) fetches a fresh link for it when the package builds. makepkg then checks the file against its SHA-256 like any other source.

## Source

- Qualcomm Compute DSP Subsystem extension 1.0.1610.0000 for the Galaxy Book Go 5G PAKA (Windows Update 200.0.27.0), `wu://c1683501-e39b-43ea-9ed7-760628657129/1/6c7c5c53ec9572114ee007f3783895ef7a326e0d`, 3 MB, SHA-256 `fa047caf3d3e7351751befb0ebbc071f5ff4483d19fbf457529c4cb13b87eed2`, checked 2026-11-16.
- Qualcomm Audio DSP Subsystem extension 1.0.1530.0004 for the Galaxy Book Go 5G PAKA (Windows Update 200.0.27.0), `wu://c1683501-e39b-43ea-9ed7-760628657129/1/6ae4450dec4009519f7aec7832a2b9176c187212`, 7 MB, SHA-256 `857039f77660ebd73b4a7164afa346dc917a135f1f3443b2d92dc80bf254eb8e`, checked 2026-11-16.
- Qualcomm Adreno graphics driver 27.20.1610.0000 for the Galaxy Book Go 5G PAKA (Windows Update 200.0.27.0), `wu://c1683501-e39b-43ea-9ed7-760628657129/1/0b15d3f4f3b663ae0d4e77addbc418d72af8738e`, 34 MB, SHA-256 `2a594be549a3f1dc525775fee7ac222f260f8fbe91b52da731c84784b9957941`, checked 2026-11-16.
- Qualcomm Modem Subsystem extension 1.0.1610.0000 for the Galaxy Book Go 5G PAKA (Windows Update 200.0.27.0), `wu://c1683501-e39b-43ea-9ed7-760628657129/1/1c2218b3e8ad9991124be524f1d7e40d8414159a`, 36 MB, SHA-256 `e62bc5b5822302caad327515240fb3b0ca828dca0318bdf59c89ce13e93816ab`, checked 2026-11-16.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/sc8180xp/Samsung/galaxy-book-go-5g/qcadsp8180.mbn` | `e1c9613ea1fd584b9243c13a41d036d172e375c94d2eda8daf1ee789e660ecbb` | Qualcomm Audio DSP Subsystem extension 1.0.1530.0004 for the Galaxy Book Go 5G PAKA (Windows Update 200.0.27.0), `qcadsp8180.mbn` |
| `qcom/sc8180xp/Samsung/galaxy-book-go-5g/qccdsp8180.mbn` | `8f5dc6b7f26d7c5aeca5660d1c6df71d18da4f4420b1cebea6e2f576ff81291a` | Qualcomm Compute DSP Subsystem extension 1.0.1610.0000 for the Galaxy Book Go 5G PAKA (Windows Update 200.0.27.0), `qccdsp8180.mbn` |
| `qcom/sc8180xp/Samsung/galaxy-book-go-5g/qcdxkmsuc8180.mbn` | `faaeac2c537e70053bf05b7ff6a7fb3462331c970dc55a7d2aa9fb5c4e8cc939` | Qualcomm Adreno graphics driver 27.20.1610.0000 for the Galaxy Book Go 5G PAKA (Windows Update 200.0.27.0), `qcdxkmsuc8180.mbn` |
| `qcom/sc8180xp/Samsung/galaxy-book-go-5g/qcmpss8180_nm.mbn` | `ec8668b360c215dd4a14d09e56f6b2f2e2fd7cf602a4a3d912cde746099c9bb8` | Qualcomm Modem Subsystem extension 1.0.1610.0000 for the Galaxy Book Go 5G PAKA (Windows Update 200.0.27.0), `qcmpss8180_nm.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-sc8180xp-samsung-galaxy-book-go-5g`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
