# lenovo-thinkbook-16-g7-qoy-firmware

Audio DSP, compute DSP and GPU firmware for the Lenovo ThinkBook 16 G7 QOY, from the driver bundle Lenovo publishes for it on Windows Update.

The firmware only runs if Lenovo signed it for this board, so linux-firmware cannot carry it until Lenovo submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Windows Update hands out short-lived links only, so a `wu://` source names the update ID, revision and SHA-1 of a file, and [wudrivers](https://github.com/birkskyum/wudrivers) fetches a fresh link for it when the package builds. makepkg then checks the file against its SHA-256 like any other source.

## Source

- Qualcomm Audio DSP Subsystem extension 2.0.4248.1000 for the 21NH (Windows Update 200.0.21.0), `wu://ee26dfb9-8d80-4eb7-8017-6ba24022412c/1/26e4b6286ce79b6d0112552e8133a6018395c38e`, 14 MB, SHA-256 `fdbac05da6490bf621d715112ea68fef19fc3de025f5768386e5700855abad9e`, checked 2026-11-15.
- Qualcomm Compute DSP Subsystem extension 30.0.0140.1000 for the 21NH (Windows Update 200.0.21.0), `wu://ee26dfb9-8d80-4eb7-8017-6ba24022412c/1/747466cde047783a391760230cbca3195a2df7b3`, 11 MB, SHA-256 `d6e5f7c9affca5d3aa93f384841676bf93750e285acc2e26461081c3857cf00a`, checked 2026-11-15.
- Qualcomm Adreno graphics driver 31.0.96.0 for the 21NH (Windows Update 200.0.21.0), `wu://ee26dfb9-8d80-4eb7-8017-6ba24022412c/1/e4da45e7d76bb3d109312897dbfa15e7446df9d9`, 86 MB, SHA-256 `aa86b26d1a91ce66990a915e4f26798ff547779e537aebadb175d30e56ad09d8`, checked 2026-11-15.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/x1p42100/LENOVO/21NH/adsp_dtbs.elf` | `09b0518af0362fb34b0492d1c4081033313ba32fd94dc07a51b05a3122e55033` | Qualcomm Audio DSP Subsystem extension 2.0.4248.1000 for the 21NH (Windows Update 200.0.21.0), `adsp_dtbs.elf` |
| `qcom/x1p42100/LENOVO/21NH/adspr.jsn` | `4b9566fcfdc1656c38d8158d79db6964e9c4b57a6e42b46241e8d63aabc42d8d` | Qualcomm Audio DSP Subsystem extension 2.0.4248.1000 for the 21NH (Windows Update 200.0.21.0), `adspr.jsn` |
| `qcom/x1p42100/LENOVO/21NH/adsps.jsn` | `19b1396b5e2c0d14fb8a4eb8e47181df7f62989f4af519b439cf0ee45a46f76e` | Qualcomm Audio DSP Subsystem extension 2.0.4248.1000 for the 21NH (Windows Update 200.0.21.0), `adsps.jsn` |
| `qcom/x1p42100/LENOVO/21NH/adspua.jsn` | `d65dc1aedce2c1131da8ffaed7dcffc05cc9c58da491e0c39acb2ac5b3f4bc1d` | Qualcomm Audio DSP Subsystem extension 2.0.4248.1000 for the 21NH (Windows Update 200.0.21.0), `adspua.jsn` |
| `qcom/x1p42100/LENOVO/21NH/battmgr.jsn` | `b8aad1d149128f414eb1fd6fcbb6e0a5b7dabcd2cba001599e1ce9a0e2e291a4` | Qualcomm Audio DSP Subsystem extension 2.0.4248.1000 for the 21NH (Windows Update 200.0.21.0), `battmgr.jsn` |
| `qcom/x1p42100/LENOVO/21NH/cdsp_dtbs.elf` | `1e0535bd2a8adcd14d6079ffa99f6fce5c6561d4759a60f6076dcfbaa4437f8a` | Qualcomm Compute DSP Subsystem extension 30.0.0140.1000 for the 21NH (Windows Update 200.0.21.0), `cdsp_dtbs.elf` |
| `qcom/x1p42100/LENOVO/21NH/cdspr.jsn` | `7e46c515ab1bb012768be6e961eca69b1c8aad9af1cbac886b3b5ae8d4228f64` | Qualcomm Compute DSP Subsystem extension 30.0.0140.1000 for the 21NH (Windows Update 200.0.21.0), `cdspr.jsn` |
| `qcom/x1p42100/LENOVO/21NH/qcadsp8380.mbn` | `4e0af6492355e4264a183728b6251a416a6cb2fa4ee2a4baca076cfb8d433c64` | Qualcomm Audio DSP Subsystem extension 2.0.4248.1000 for the 21NH (Windows Update 200.0.21.0), `qcadsp8380.mbn` |
| `qcom/x1p42100/LENOVO/21NH/qccdsp8380.mbn` | `4387fa1a234aacbff50f8a215b96536d17c4b25b6b798392e15a162e4adcd7a0` | Qualcomm Compute DSP Subsystem extension 30.0.0140.1000 for the 21NH (Windows Update 200.0.21.0), `qccdsp8380.mbn` |
| `qcom/x1p42100/LENOVO/21NH/qcdxkmsucpurwa.mbn` | `f9342cb44a79f5abdd1f0ae888c6c3df8e60f28a6c3a5077591369268d1b5c0a` | Qualcomm Adreno graphics driver 31.0.96.0 for the 21NH (Windows Update 200.0.21.0), `qcdxkmsucpurwa.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-x1p42100-lenovo-21nh`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
