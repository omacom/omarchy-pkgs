# asus-vivobook-s16-firmware

Audio DSP, compute DSP, GPU and video firmware for the ASUS Vivobook S 16, from ASUS's own Windows driver download.

The firmware only runs if ASUS signed it for this board, so linux-firmware cannot carry it until ASUS submits it. The package holds no firmware itself. Its recipe downloads the driver package below when the package is built, unpacks it without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

## Source

- [S3407QA V1.311.8800.0](https://dlcdnets.asus.com/pub/ASUS/nb/Image/Driver/DriverPackage/50069/SOCPackage_forWebSite_Qualcomm_Z_V1.311.8800.0_50069.exe), 386 MB, SHA-256 `ebb9d7094af88def949eeca8ba6ca8e7bf49c8d2f73e11f40079b13c2c298842`, checked 2026-11-02.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/x1p42100/ASUSTeK/vivobook-s16/adsp_dtbs.elf` | `4efd01feefccc344874cc8d4d3600231310d228216fa16a8740ac5fcc5357ced` | S3407QA V1.311.8800.0, `QualcommBSP/Subsystem/qcsubsys_ext_adsp8380/adsp_dtbs.elf` |
| `qcom/x1p42100/ASUSTeK/vivobook-s16/adspr.jsn` | `e9ba7199626b0c03f2ec02822d744f678ad567fe0625a28fe5f5908b7281e9db` | S3407QA V1.311.8800.0, `QualcommBSP/Subsystem/qcsubsys_ext_adsp8380/adspr.jsn` |
| `qcom/x1p42100/ASUSTeK/vivobook-s16/adsps.jsn` | `19b1396b5e2c0d14fb8a4eb8e47181df7f62989f4af519b439cf0ee45a46f76e` | S3407QA V1.311.8800.0, `QualcommBSP/Subsystem/qcsubsys_ext_adsp8380/adsps.jsn` |
| `qcom/x1p42100/ASUSTeK/vivobook-s16/adspua.jsn` | `d65dc1aedce2c1131da8ffaed7dcffc05cc9c58da491e0c39acb2ac5b3f4bc1d` | S3407QA V1.311.8800.0, `QualcommBSP/Subsystem/qcsubsys_ext_adsp8380/adspua.jsn` |
| `qcom/x1p42100/ASUSTeK/vivobook-s16/battmgr.jsn` | `b8aad1d149128f414eb1fd6fcbb6e0a5b7dabcd2cba001599e1ce9a0e2e291a4` | S3407QA V1.311.8800.0, `QualcommBSP/Subsystem/qcsubsys_ext_adsp8380/battmgr.jsn` |
| `qcom/x1p42100/ASUSTeK/vivobook-s16/cdsp_dtbs.elf` | `d2e81a2430ec9474aa46558a9568262b7fde3ae31bdc523028306454fb11d3b0` | S3407QA V1.311.8800.0, `QualcommBSP/NPU/qcnspmcdm_ext_cdsp8380/cdsp_dtbs.elf` |
| `qcom/x1p42100/ASUSTeK/vivobook-s16/cdspr.jsn` | `7e46c515ab1bb012768be6e961eca69b1c8aad9af1cbac886b3b5ae8d4228f64` | S3407QA V1.311.8800.0, `QualcommBSP/NPU/qcnspmcdm_ext_cdsp8380/cdspr.jsn` |
| `qcom/x1p42100/ASUSTeK/vivobook-s16/qcadsp8380.mbn` | `5799e03a04e0f66dfec6a6230abd13dc742e6bb347d509e86d826382749c2b8b` | S3407QA V1.311.8800.0, `QualcommBSP/Subsystem/qcsubsys_ext_adsp8380/qcadsp8380.mbn` |
| `qcom/x1p42100/ASUSTeK/vivobook-s16/qccdsp8380.mbn` | `e7f15a411d59f0aa91cadf3dec0366cd916af240c956731577c53a40d8343e64` | S3407QA V1.311.8800.0, `QualcommBSP/NPU/qcnspmcdm_ext_cdsp8380/qccdsp8380.mbn` |
| `qcom/x1p42100/ASUSTeK/vivobook-s16/qcdxkmsucpurwa.mbn` | `5b8b1ea1de11b9acc74fdd4919aa4aeac924520e4b11cf27782c593640e11e44` | S3407QA V1.311.8800.0, `QualcommBSP/GFX/qcdx8380/qcdxkmsucpurwa.mbn` |
| `qcom/x1p42100/ASUSTeK/vivobook-s16/qcvss8380.mbn` | `c85e552d4ee9e2e60166d658f509307caf879b56ef079696959c5fbcfe44c9fc` | S3407QA V1.311.8800.0, `QualcommBSP/GFX/qcdx8380/qcvss8380_pa.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-x1p42100-asustek-vivobook-s16`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
