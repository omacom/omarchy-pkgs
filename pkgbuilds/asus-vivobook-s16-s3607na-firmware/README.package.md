# asus-vivobook-s16-s3607na-firmware

Audio DSP and compute DSP firmware for the ASUS Vivobook S16 S3607NA, from ASUS's own Windows driver download.

The firmware only runs if ASUS signed it for this board, so linux-firmware cannot carry it until ASUS submits it. The package holds no firmware itself. Its recipe downloads the driver package below when the package is built, unpacks it without running it, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

## Source

- [S3607NA V1.309.4500.0](https://dlcdnets.asus.com/pub/ASUS/nb/Image/Driver/DriverPackage/48976/SOCPackage_forWebSite_Qualcomm_Z_V1.309.4500.0_48976.exe), 413 MB, SHA-256 `3be6e7b17ea332999beee48cca8bc70a40bfd1d76ba740056b404bed3adbada0`, checked 2026-11-14.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/glymur/ASUSTeK/S3607NA/adsp_dtbs.elf` | `213b2eba8f82a387806b6e334d5fdcaf6325acdb5f03a3c1d03a9ecb9c611a18` | S3607NA V1.309.4500.0, `QualcommBSP/Subsystem/qcsubsys_ext_adsp8480/adsp_dtbs.elf` |
| `qcom/glymur/ASUSTeK/S3607NA/adspr.jsn` | `66ce8531efb7979d234e0f0eabbe18d038ac97da771a8a194f613df8f0724e81` | S3607NA V1.309.4500.0, `QualcommBSP/Subsystem/qcsubsys_ext_adsp8480/adspr.jsn` |
| `qcom/glymur/ASUSTeK/S3607NA/adsps.jsn` | `12ac2f3ae8ced12aa4b06b3ab3a01bc4d8efe1c92ebea503c002f209a6ec176f` | S3607NA V1.309.4500.0, `QualcommBSP/Subsystem/qcsubsys_ext_adsp8480/adsps.jsn` |
| `qcom/glymur/ASUSTeK/S3607NA/adspua.jsn` | `982a99853495e34726b8e44697fdfad303334de0a67cbf6cde306c8f1731000b` | S3607NA V1.309.4500.0, `QualcommBSP/Subsystem/qcsubsys_ext_adsp8480/adspua.jsn` |
| `qcom/glymur/ASUSTeK/S3607NA/cdsp_dtbs.elf` | `9bee104a48d4aac647287d6c1454df170c1cff7158a2352711fd1e2163ea6d1d` | S3607NA V1.309.4500.0, `QualcommBSP/NPU/qcnspmcdm8480/cdsp_dtbs.elf` |
| `qcom/glymur/ASUSTeK/S3607NA/qcadsp8480.mbn` | `6e98746ddb4a4c1b8c11f13f99319a1bf2e13ea6e9911865e120dfb27972b34d` | S3607NA V1.309.4500.0, `QualcommBSP/Subsystem/qcsubsys_ext_adsp8480/qcadsp8480.mbn` |
| `qcom/glymur/ASUSTeK/S3607NA/qccdsp8480.mbn` | `acf13d29288d283793f418a36650e8a261eed927d30de109a59cb2210f458794` | S3607NA V1.309.4500.0, `QualcommBSP/NPU/qcnspmcdm8480/qccdsp8480.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-glymur-asustek-s3607na`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
