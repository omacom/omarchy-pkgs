# lenovo-ideapad-slim-5x-firmware

Audio DSP, compute DSP, GPU and video firmware for the Lenovo IdeaPad Slim 5x 14Q8X9, from the driver bundle Lenovo publishes for it on Windows Update.

The firmware only runs if Lenovo signed it for this board, so linux-firmware cannot carry it until Lenovo submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Windows Update hands out short-lived links only, so a `wu://` source names the update ID, revision and SHA-1 of a file, and [wudrivers](https://github.com/birkskyum/wudrivers) fetches a fresh link for it when the package builds. makepkg then checks the file against its SHA-256 like any other source.

Its files are byte for byte the ones in `qcom/x1p42100/LENOVO/83HL`, which the table links them to as linux-firmware's WHENCE would, so the recipe can take them from another machine's download, the smallest that holds them.

## Source

- Qualcomm Audio DSP Subsystem extension 2.0.7800.0002 for the 83HL (Windows Update 200.0.20.0), `wu://96d7ff14-22cd-4939-a225-706d86c26a7e/1/5c9d4b84b92ca212f76cfb0614ada8f5ad955e1f`, 14 MB, SHA-256 `d2678c170b1403d604acffb244ccfe4b4c661ddbc60010692dc9abaa9f406bc5`, checked 2026-11-15.
- Qualcomm Compute DSP Subsystem extension 30.0.0140.1000 for the 83HL (Windows Update 200.0.20.0), `wu://96d7ff14-22cd-4939-a225-706d86c26a7e/1/747466cde047783a391760230cbca3195a2df7b3`, 11 MB, SHA-256 `d6e5f7c9affca5d3aa93f384841676bf93750e285acc2e26461081c3857cf00a`, checked 2026-11-15.
- Qualcomm Adreno graphics driver 31.0.98.1 for the 83HL (Windows Update 200.0.20.0), `wu://96d7ff14-22cd-4939-a225-706d86c26a7e/1/4b62ce39ab5c4fc4494918680e4be1a83b71cea8`, 86 MB, SHA-256 `20c61a5de20d33d359b1c0848710098c2c82169af686dca68090f9efdee15db2`, checked 2026-11-15.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/x1p42100/LENOVO/83HL/adsp_dtbs.elf` | `27a676b110165d38723f01d88543a40603596e892c00019f67fa6013c591b6ab` | Qualcomm Audio DSP Subsystem extension 2.0.7800.0002 for the 83HL (Windows Update 200.0.20.0), `adsp_dtbs.elf` |
| `qcom/x1p42100/LENOVO/83HL/adspr.jsn` | `549bb9c8e32dc6253d0d0ddde2ce5c26f75f8333d3e55861f297e169a9f3e5c0` | Qualcomm Audio DSP Subsystem extension 2.0.7800.0002 for the 83HL (Windows Update 200.0.20.0), `adspr.jsn` |
| `qcom/x1p42100/LENOVO/83HL/adsps.jsn` | `12ac2f3ae8ced12aa4b06b3ab3a01bc4d8efe1c92ebea503c002f209a6ec176f` | Qualcomm Audio DSP Subsystem extension 2.0.7800.0002 for the 83HL (Windows Update 200.0.20.0), `adsps.jsn` |
| `qcom/x1p42100/LENOVO/83HL/adspua.jsn` | `982a99853495e34726b8e44697fdfad303334de0a67cbf6cde306c8f1731000b` | Qualcomm Audio DSP Subsystem extension 2.0.7800.0002 for the 83HL (Windows Update 200.0.20.0), `adspua.jsn` |
| `qcom/x1p42100/LENOVO/83HL/battmgr.jsn` | `be8c6fba330908e4683fb6282761cb08485a302d6a66e09721e102e342f27236` | Qualcomm Audio DSP Subsystem extension 2.0.7800.0002 for the 83HL (Windows Update 200.0.20.0), `battmgr.jsn` |
| `qcom/x1p42100/LENOVO/83HL/cdsp_dtbs.elf` | `1e0535bd2a8adcd14d6079ffa99f6fce5c6561d4759a60f6076dcfbaa4437f8a` | Qualcomm Compute DSP Subsystem extension 30.0.0140.1000 for the 83HL (Windows Update 200.0.20.0), `cdsp_dtbs.elf` |
| `qcom/x1p42100/LENOVO/83HL/cdspr.jsn` | `7e46c515ab1bb012768be6e961eca69b1c8aad9af1cbac886b3b5ae8d4228f64` | Qualcomm Compute DSP Subsystem extension 30.0.0140.1000 for the 83HL (Windows Update 200.0.20.0), `cdspr.jsn` |
| `qcom/x1p42100/LENOVO/83HL/qcadsp8380.mbn` | `fd71bd1a2d8224ca58c9f5aee6ad14f151a093dfbee792169b64745c86e51a29` | Qualcomm Audio DSP Subsystem extension 2.0.7800.0002 for the 83HL (Windows Update 200.0.20.0), `qcadsp8380.mbn` |
| `qcom/x1p42100/LENOVO/83HL/qccdsp8380.mbn` | `4387fa1a234aacbff50f8a215b96536d17c4b25b6b798392e15a162e4adcd7a0` | Qualcomm Compute DSP Subsystem extension 30.0.0140.1000 for the 83HL (Windows Update 200.0.20.0), `qccdsp8380.mbn` |
| `qcom/x1p42100/LENOVO/83HL/qcdxkmsucpurwa.mbn` | `23788d4891403545c6d28cf09d97c5f6e81d9aed9d5f155c21fc8b39d03ef2a7` | Qualcomm Adreno graphics driver 31.0.98.1 for the 83HL (Windows Update 200.0.20.0), `qcdxkmsucpurwa.mbn` |
| `qcom/x1p42100/LENOVO/83HL/qcvss8380.mbn` | `d153ae5029a19d734c9ff3149906abcddc93763ea493d1827974d61bac324bd3` | Qualcomm Adreno graphics driver 31.0.98.1 for the 83HL (Windows Update 200.0.20.0), `qcvss8380_pa.mbn` |
| `qcom/x1p42100/LENOVO/83HL/qcvss8380_pa.mbn` | `d153ae5029a19d734c9ff3149906abcddc93763ea493d1827974d61bac324bd3` | Qualcomm Adreno graphics driver 31.0.98.1 for the 83HL (Windows Update 200.0.20.0), `qcvss8380_pa.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-x1p42100-lenovo-83hl`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
