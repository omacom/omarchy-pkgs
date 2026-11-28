# xiaomi-book-s-firmware

Audio DSP, compute DSP, GPU and modem firmware for the Xiaomi Book S 12.4, from the driver bundle Xiaomi publishes for it on Windows Update.

The firmware only runs if Xiaomi signed it for this board, so linux-firmware cannot carry it until Xiaomi submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Windows Update hands out short-lived links only, so a `wu://` source names the update ID, revision and SHA-1 of a file, and [wudrivers](https://github.com/birkskyum/wudrivers) fetches a fresh link for it when the package builds. makepkg then checks the file against its SHA-256 like any other source.

## Source

- Qualcomm WCN3990 Wi-Fi driver 1.0.1600.0000 for the Xiaomi Book S 12.4 TM2133-39542 (Windows Update 200.0.3.0), `wu://b7c0eed1-5795-4369-a9e2-bd3476a9a6f3/1/7c6e2e599cd9e0774188aabd2a224e5a1f511eda`, 2 MB, SHA-256 `38e379b0c47329c1c0e1a0eb35e0c0ac30e5e6040a0fe4b1c987d20001362f86`, checked 2026-11-16.
- Qualcomm Compute DSP Subsystem extension 1.0.1680.0000 for the Xiaomi Book S 12.4 TM2133-39542 (Windows Update 200.0.3.0), `wu://b7c0eed1-5795-4369-a9e2-bd3476a9a6f3/1/ca592613684a8221f0679747179930ea10a924fd`, 3 MB, SHA-256 `845cc8429d503d8e96f6f90d1b6a0baa02748338b4c236fb2182572e64a6eb27`, checked 2026-11-16.
- Qualcomm Audio DSP Subsystem extension 1.0.1680.0007 for the Xiaomi Book S 12.4 TM2133-39542 (Windows Update 200.0.3.0), `wu://b7c0eed1-5795-4369-a9e2-bd3476a9a6f3/1/c595814c7ed4870c280e0cb9037ba3fd14e1aa8f`, 7 MB, SHA-256 `b191e39eb7127f918fd85bffaddaa98d9ce8c8ed7f3f8134d72438bf7884870e`, checked 2026-11-16.
- Qualcomm Adreno graphics driver 27.20.1720.0000 for the Xiaomi Book S 12.4 TM2133-39542 (Windows Update 200.0.3.0), `wu://b7c0eed1-5795-4369-a9e2-bd3476a9a6f3/1/4a210ed861b59da3552cba689cd594473892b1d5`, 34 MB, SHA-256 `55e519adbba0823619e90853503e91230b5df16b80abcb5fbc3082c9ba52ba36`, checked 2026-11-16.
- Qualcomm Modem Subsystem extension 1.0.1680.0002 for the Xiaomi Book S 12.4 TM2133-39542 (Windows Update 200.0.3.0), `wu://b7c0eed1-5795-4369-a9e2-bd3476a9a6f3/1/011112f8b5a3281cd5738e91e808ed17aaf3468c`, 36 MB, SHA-256 `056325c564110c1c0c86ac13a2b23a60b54f6196524efbcec2e718eb2b790313`, checked 2026-11-16.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/sc8180xp/Xiaomi/book-s/qcadsp8180.mbn` | `16cc74a719f6da4ab1a160729e83f7072ade33c139a430c747bbd3a35ebc43a2` | Qualcomm Audio DSP Subsystem extension 1.0.1680.0007 for the Xiaomi Book S 12.4 TM2133-39542 (Windows Update 200.0.3.0), `qcadsp8180.mbn` |
| `qcom/sc8180xp/Xiaomi/book-s/qccdsp8180.mbn` | `565fdf3ede556725c96e95d630353a3c1d81baf1b907fcd9a6a687f06c4b007f` | Qualcomm Compute DSP Subsystem extension 1.0.1680.0000 for the Xiaomi Book S 12.4 TM2133-39542 (Windows Update 200.0.3.0), `qccdsp8180.mbn` |
| `qcom/sc8180xp/Xiaomi/book-s/qcdxkmsuc8180.mbn` | `660c66fd69ced64004a173978cabfdbe569ec7aea1dc43657033fbf93778328f` | Qualcomm Adreno graphics driver 27.20.1720.0000 for the Xiaomi Book S 12.4 TM2133-39542 (Windows Update 200.0.3.0), `qcdxkmsuc8180.mbn` |
| `qcom/sc8180xp/Xiaomi/book-s/qcmpss8180_nm.mbn` | `cbbb0af0cd1249f4dc29dbef909935f0e8009e674ffaf48f3e4f8f17e7c41175` | Qualcomm Modem Subsystem extension 1.0.1680.0002 for the Xiaomi Book S 12.4 TM2133-39542 (Windows Update 200.0.3.0), `qcmpss8180_nm.mbn` |
| `qcom/sc8180xp/Xiaomi/book-s/wlanmdsp.mbn` | `2f27b0656b7de62859f0dddaa51f4d90d3a5d5357a1db433e1ba360f0a5df0bc` | Qualcomm WCN3990 Wi-Fi driver 1.0.1600.0000 for the Xiaomi Book S 12.4 TM2133-39542 (Windows Update 200.0.3.0), `WLANMDSP.MBN` |

## How Omarchy installs it

The package provides `qcom-firmware-sc8180xp-xiaomi-book-s`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
