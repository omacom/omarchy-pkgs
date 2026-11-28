# asus-v400-aio-vm441qa-firmware

Audio DSP, compute DSP, GPU and video firmware for the ASUS V400 AiO VM441QA, from ASUS's own Windows driver download.

The firmware only runs if ASUS signed it for this board, so linux-firmware cannot carry it until ASUS submits it. The package holds no firmware itself. Its recipe downloads the driver package below when the package is built, unpacks it without running it, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

## Source

- [VM441QA V1.301.8600.0](https://dlcdnets.asus.com/pub/ASUS/All-In-One/Image/Driver/DriverPackage/52327/SOCPackage_forWebSite_CC_Qualcomm_F_V1.301.8600.0_52327.exe), 384 MB, SHA-256 `eccefbecd75a2bf8d938cb8589f761192b143972baeeb46367bddd8018179fa3`, checked 2026-11-14.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/x126100/ASUSTeK/VM441QA/adsp_dtbs.elf` | `8d88e7b2c524bad1eca5a5b9356b48e02d02d4934badeef387846d0d0fb0eb5a` | VM441QA V1.301.8600.0, `QualcommBSP/qcsubsys_ext_adsp8380/adsp_dtbs.elf` |
| `qcom/x126100/ASUSTeK/VM441QA/adspr.jsn` | `4b9566fcfdc1656c38d8158d79db6964e9c4b57a6e42b46241e8d63aabc42d8d` | VM441QA V1.301.8600.0, `QualcommBSP/qcsubsys_ext_adsp8380/adspr.jsn` |
| `qcom/x126100/ASUSTeK/VM441QA/adsps.jsn` | `19b1396b5e2c0d14fb8a4eb8e47181df7f62989f4af519b439cf0ee45a46f76e` | VM441QA V1.301.8600.0, `QualcommBSP/qcsubsys_ext_adsp8380/adsps.jsn` |
| `qcom/x126100/ASUSTeK/VM441QA/adspua.jsn` | `d65dc1aedce2c1131da8ffaed7dcffc05cc9c58da491e0c39acb2ac5b3f4bc1d` | VM441QA V1.301.8600.0, `QualcommBSP/qcsubsys_ext_adsp8380/adspua.jsn` |
| `qcom/x126100/ASUSTeK/VM441QA/cdsp_dtbs.elf` | `9ea41f43725e0210de43714ea232e60f7610eb118f79df4f7877db88a8eda87d` | VM441QA V1.301.8600.0, `QualcommBSP/qcnspmcdm_ext_cdsp8380/cdsp_dtbs.elf` |
| `qcom/x126100/ASUSTeK/VM441QA/cdspr.jsn` | `7e46c515ab1bb012768be6e961eca69b1c8aad9af1cbac886b3b5ae8d4228f64` | VM441QA V1.301.8600.0, `QualcommBSP/qcnspmcdm_ext_cdsp8380/cdspr.jsn` |
| `qcom/x126100/ASUSTeK/VM441QA/qcadsp8380.mbn` | `b2ef4fc7a033bd8f6f2c9f06a66d8d693e8b5bc31cc4144ca22b4279b8d8c02b` | VM441QA V1.301.8600.0, `QualcommBSP/qcsubsys_ext_adsp8380/qcadsp8380.mbn` |
| `qcom/x126100/ASUSTeK/VM441QA/qccdsp8380.mbn` | `efcffa4cb458ee1f2b3ac7f81b14873662e7898426ff801695bfb6d6719cabbe` | VM441QA V1.301.8600.0, `QualcommBSP/qcnspmcdm_ext_cdsp8380/qccdsp8380.mbn` |
| `qcom/x126100/ASUSTeK/VM441QA/qcdxkmsucpurwa.mbn` | `376de9d57d2b9249a92871a17d78200d8d5c750b3ceca49aa0f6799facf7c844` | VM441QA V1.301.8600.0, `QualcommBSP/qcdx8380/qcdxkmsucpurwa.mbn` |
| `qcom/x126100/ASUSTeK/VM441QA/qcvss8380_pa.mbn` | `5c4b6370b851c47f4884e6c6530b2ac4b83321770274a6e0e0642542fd3d2396` | VM441QA V1.301.8600.0, `QualcommBSP/qcdx8380/qcvss8380_pa.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-x126100-asustek-vm441qa`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
